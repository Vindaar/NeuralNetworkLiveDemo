import websocket, asynchttpserver, asyncnet, asyncdispatch
import seqmath
import sequtils, strformat, strutils, tables
import plotly
import chroma
import arraymancer
import algorithm
import json
import random

# import from this project
import protocol

let server = newAsyncHttpServer()

template prepareMnist() {.dirty.} =
  ## dirty template to keep `cb` cleaner
  # first prepare data
  let
    x_train = read_mnist_images("/home/schmidt/mnist/train-images-idx3-ubyte").astype(float64) / 255'f32
    y_train = read_mnist_labels("/home/schmidt/mnist/train-labels-idx1-ubyte").astype(int)

  const title = "MNIST example: label "

proc cb(req: Request) {.async.} =
  ## callback function of the WebSocket server, which contains the event loop in
  ## which we (will) train the MLP and send the data to the plotly client

  # call dirty template, which creates all MNIST related variables
  prepareMnist()
  # get the plotly `Plot` objects
  let (p_mnist, p_pred, p_error) = preparePlotly()

  let (ws, error) = await verifyWebsocketRequest(req)#, "myfancyprotocol")

  if ws.isNil:
    echo "WS negotiation failed: ", error
    await req.respond(Http400, "Websocket negotiation failed: " & error)
    req.client.close()
    return

  echo "New websocket customer arrived!"
  var i = 0
  for ind in 0 ..< x_train.shape[0]:
    let (opcode, data) = await ws.readData()
    try:
      echo "(opcode: ", opcode, ", data length: ", data.len, ")"
      # case on the different opcodes (only use Text though)
      case opcode
      of Opcode.Text:
        echo data
        let
          im = x_train[ind,_,_].clone.squeeze
          # return  this
          im2d = im.data.reshape2D([28, 28]).reversed
        # replace the data on the `Plot`
        p_mnist.datas[0].zs = im2d
        # modify title and set new layout
        p_mnist.layout.title = title & $y_train[ind]
        # create the data packet according to protocol and send
        let dataPack = createDataPacket(p_mnist, p_pred, 1.1)
        echo "Send packet ", dataPack
        waitFor ws.sendText(dataPack)
      of Opcode.Binary:
        waitFor ws.sendBinary(data)
      of Opcode.Close:
        asyncCheck ws.close()
        let (closeCode, reason) = extractCloseData(data)
        echo "socket went away, close code: ", closeCode, ", reason: ", reason
      else: discard
    except:
      echo "encountered exception: ", getCurrentExceptionMsg()

proc main() =
  # create and run the websocket server
  waitFor server.serve(Port(8080), cb)

when isMainModule:
  main()
