import websocket, asynchttpserver, asyncnet, asyncdispatch
import seqmath
import sequtils, strformat, strutils, tables
import plotly
import chroma
import arraymancer
import algorithm
import json
import random
import macros
import threadpool

# import from this project
import protocol

let server = newAsyncHttpServer()
const pretitle = "MNIST example: "
const title = "label "

var
  imChannel: Channel[seq[float32]]
  yprChannel: Channel[seq[float32]]
  errChannel: Channel[(float, float)]
  startChannel: Channel[bool]

imChannel.open(0)
yprChannel.open(0)
errChannel.open(0)
startChannel.open(1)

template prepareDatasets() {.dirty.} =
  # Idem for testing data (10000 images)
  let
    x_test = read_mnist_images("build/t10k-images.idx3-ubyte").astype(float32) / 255'f32
    y_test = read_mnist_labels("build/t10k-labels.idx1-ubyte").astype(int)


template prepareMnist() {.dirty.} =
  ## dirty template to keep `cb` cleaner
  # first prepare data
  let
    ctx = newContext Tensor[float32] # Autograd/neural network graph
    n = 16                           # Batch size

  let
    # Training data is 60k 28x28 greyscale images from 0-255,
    # neural net prefers input rescaled to [0, 1] or [-1, 1]
    x_train = read_mnist_images("build/train-images.idx3-ubyte").astype(float32) / 255'f32

    # Change shape from [N, H, W] to [N, C, H, W], with C = 1 (unsqueeze). Convolution expect 4d tensors
    # And store in the context to track operations applied and build a NN graph
    # X_train = ctx.variable x_train.reshape([x_train.shape[0], 28*28]).unsqueeze(1)
    # in case of MLP we simply reshape
    X_train = ctx.variable x_train.reshape([x_train.shape[0], 28*28])
    # Labels are uint8, we must convert them to int
    y_train = read_mnist_labels("build/train-labels.idx1-ubyte").astype(int)

    # Idem for testing data (10000 images)
    x_test = read_mnist_images("build/t10k-images.idx3-ubyte").astype(float32) / 255'f32
    #X_test = ctx.variable x_test.reshape([x_test.shape[0], 28*28]).unsqueeze(1)
    X_test = ctx.variable x_test.reshape([x_test.shape[0], 28*28])
    y_test = read_mnist_labels("build/t10k-labels.idx1-ubyte").astype(int)

  echo "shape of x_train ", x_train.shape
  echo "rank of  x_train ", x_train.rank
  echo "reshape ", x_train.reshape([x_train.shape[0], 28*28]).shape

  # Configuration of the neural network
  # see ex02 for CNN example
  network ctx, DemoNet:
    layers:
      x:          Input(28 * 28)
      hidden:     Linear(x.out_shape, 1000)
      classifier: Linear(hidden.out_shape, 10)
    forward x:
      x.hidden.relu.classifier

  let model = ctx.init(DemoNet)

  # Stochastic Gradient Descent (API will change)
  let optim = model.optimizerSGD(learning_rate = 0.1'f32)

proc trainMlp() =
  ## performs the training of the simple MLP. Runs in a separate thread and sends data
  ## via global channels to the async thread, which servers the WebSocket server
  ## Note: code based on arraymancer example 02

  # call dirty template, which creates all MNIST related variables
  prepareMnist()

  discard startChannel.recv()

  # counter variable as `fake epoch` for data to be transmitted
  var counter = 0
  # Learning loop
  for epoch in 0 ..< 200:
    for batch_id in 0 ..< X_train.value.shape[0] div n: # some at the end may be missing, oh well ...
      # minibatch offset in the Tensor
      let offset = batch_id * n
      let x = X_train[offset ..< offset + n, _]
      let target = y_train[offset ..< offset + n]

      # Running through the network and computing loss
      let clf = model.forward(x)
      let loss = clf.sparse_softmax_cross_entropy(target)

      if batch_id mod 200 == 0:
        # Print status every 200 batches
        echo "Epoch is: " & $epoch
        echo "Batch id: " & $batch_id
        echo "Loss is:  " & $loss.value.data[0]

      # Compute the gradient (i.e. contribution of each parameter to the loss)
      loss.backprop()

      # Correct the weights now that we have the gradient information
      optim.update()

      # now send the data
      var y_preds: Tensor[float32]
      var ims: Tensor[float32]
      var score = 0.0
      if batch_id mod 2 == 0:
        # TODO: rework this maybe and make the `10` a command line option
        ctx.no_grad_mode:
          let y_pred = model.forward(X_test[0 ..< 1000, _]).value.softmax
          y_preds = y_pred
          ims = x_test[0 ..< 1000, _]
          score += accuracy_score(y_test[0 ..< 1000], y_pred.argmax(axis = 1).squeeze)
          # now send something via the channel
          imChannel.send(ims[counter,_,_].clone.squeeze.data)
          yprChannel.send(y_preds[counter,_].clone.squeeze.data)
          errChannel.send((counter.float, score))
        inc counter
    # Validation (checking the accuracy/generalization of our model on unseen data)
    ctx.no_grad_mode:
      echo "\nEpoch #" & $epoch & " done. Testing accuracy"

      # To avoid using too much memory we will compute accuracy in 10 batches of 1000 images
      # instead of loading 10 000 images at once
      var loss = 0.0
      var score = 0.0
      for i in 0 ..< 10:
        let y_pred = model.forward(X_test[i*1000 ..< (i+1)*1000, _]).value.softmax
        echo "Y pred is ", y_pred.shape
        score += accuracy_score(y_test[i*1000 ..< (i+1)*1000], y_pred.argmax(axis = 1).squeeze)

        loss += model.forward(X_test[i*1000 ..< (i+1)*1000, _]).sparse_softmax_cross_entropy(y_test[i*1000 ..< (i+1)*1000]).value.data[0]
      score /= 10
      loss /= 10
      echo "Accuracy: " & $(score * 100) & "%"
      echo "Loss:     " & $loss
      echo "\n"

proc cb(req: Request) {.async.} =
  ## callback function of the WebSocket server, which contains the event loop in
  ## which we (will) train the MLP and send the data to the plotly client

  # call dirty template, which creates all MNIST related variables
  prepareDatasets()
  # get the plotly `Plot` objects
  let (p_mnist, p_pred, p_error) = preparePlotly()

  let (ws, error) = await verifyWebsocketRequest(req)

  if ws.isNil:
    echo "WS negotiation failed: ", error
    await req.respond(Http400, "Websocket negotiation failed: " & error)
    req.client.close()
    return
  else:
    # receive connection successful package
    let (opcodeConnect, dataConnect) = await ws.readData()
    if dataConnect != $Messages.Connected:
      echo "Received wrong packet, quit early"
      return

  echo "New websocket customer arrived!"
  var i = 0

  # send command to ANN training to start w/ training
  let (opcodeStart, dataStart) = await ws.readData()
  if dataStart == $Messages.Train:
    startChannel.send(true)
  else:
    # else return early
    echo "data received is ", dataStart
    return

  for epoch in 0 ..< 1000:
    # await a ping from the client to send new data
    let (opcode, data) = await ws.readData()
    # first await the packet from the connected socket, don't start training before hand
    echo "(opcode: ", opcode, ", data length: ", data.len, ", data: ", data, ")"
    # now given prediction and accuracy data, send it to client
    try:
      # case on the different opcodes (only use Text though)
      case opcode
      of Opcode.Text:
        # receive from the channel, else we cannot transmit to client
        let
          y_pred    = yprChannel.recv()
          im        = imChannel.recv()
          score_tup = errChannel.recv()
          # create correctly shaped 2D seq from 1D seq
          im2d = im.reshape2D([28, 28]).reversed

        # replace the data on the `Plot`
        p_mnist.datas[0].zs = im2d
        # modify title and set new layout
        p_mnist.layout.title = pretitle & title & $y_test[epoch]
        # set new prediction data and title
        p_pred.datas[0].zs = y_pred.reshape2D([10, 1])
        p_pred.layout.title = title & $y_test[epoch]

        let dataPack = createDataPacket(p_mnist, p_pred, score_tup)
        waitFor ws.sendText(dataPack)
      of Opcode.Close:
        asyncCheck ws.close()
        let (closeCode, reason) = extractCloseData(data)
        echo "socket went away, close code: ", closeCode, ", reason: ", reason
      else: discard
    except:
      echo "encountered exception: ", getCurrentExceptionMsg()

proc main() =
  # create and run the websocket server
  var thr: Thread[void]
  thr.createThread(trainMlp)

  waitFor server.serve(Port(8080), cb)

when isMainModule:
  main()
