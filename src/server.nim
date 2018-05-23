import websocket, asynchttpserver, asyncnet, asyncdispatch
import seqmath
import sequtils, strformat, strutils, tables
import plotly
import chroma
import arraymancer
import algorithm
import json

let server = newAsyncHttpServer()

template preparePlotly() {.dirty.} =
  ## dirty template to keep `cb` cleaner
  # first prepare data
  let
    x_train = read_mnist_images("/home/schmidt/mnist/train-images-idx3-ubyte").astype(float64) / 255'f32
    y_train = read_mnist_labels("/home/schmidt/mnist/train-labels-idx1-ubyte").astype(int)

  const title = "MNIST example: label "

  let
    d = Trace[float](mode: PlotMode.LinesMarkers, `type`: PlotType.HeatMap)
  d.colormap = ColorMap.Viridis
  # initialize data with first event
  d.zs = x_train[0,_,_].clone.squeeze.data.reshape2D([28, 28]).reversed

  let
    layout = Layout(title: &"{title} 0", width: 800, height: 800,
                    xaxis: Axis(title: "my x-axis"),
                    yaxis: Axis(title: "y-axis too"), autosize: false)
    p = Plot[float](layout: layout, datas: @[d])

proc cb(req: Request) {.async.} =

  # call dirty template, which creates all Plotly and MNIST related variables
  preparePlotly()

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
        #waitFor ws.sendText("thanks for the data!")

        let
          im = x_train[ind,_,_].clone.squeeze
          # return  this
          im2d = im.data.reshape2D([28, 28]).reversed
        # assign to the data field
        d.zs = im2d
        # replace the data on the `Plot`
        p.datas = @[d]
        var jsonTab = initOrderedTable[string, cstring](2)
        let
          # call `json` for each element of `Plot.datas`
          jsons = p.datas[0].json(as_pretty = false)
        jsonTab["trace"] = jsons
        # modify layout
        layout.title = title & $y_train[ind]
        jsonTab["layout"] = pretty(% layout)
        #let dataSend = JsonNode(kind: JObject, fields: jsonTab)
        waitFor ws.sendText($jsonTab)
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
  # simple example showcasing scatter plot with error bars

  #discard d.createSeqForHeatmap
  waitFor server.serve(Port(8080), cb)


when isMainModule:
  main()
