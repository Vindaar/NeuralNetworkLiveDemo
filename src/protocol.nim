import plotly
import chroma
import json, tables, sequtils, random, strformat

type
  DataPacket* = object
    mnTrace*: string
    mnLayout*: string
    prTrace*: string
    prLayout*: string
    erValX*: string
    erValY*: string

  DataParsingError* = object of Exception

  Messages* {.pure.} = enum
    Ping = "ping"
    Train = "Start training!"
    Connected = "connection successful!"

proc parseDataPacket*(data: cstring): DataPacket =
  ## given a `DataPacket` received from the socket, parse the JSON
  ## and return the content as a `DataPacket` instance
  var jsonData: JsonNode
  try:
    jsonData = ($data).parseJson
  except JsonParsingError:
    raise newException(DataParsingError, "Invalid JSON: " &
                       getCurrentExceptionMsg())
  except:
    raise newException(DataParsingError, "Unknown error: " &
                       getCurrentExceptionMsg())
  # fill DataPacket fields
  result.mnTrace = $jsonData["mnTrace"]
  result.mnLayout = $jsonData["mnLayout"]
  result.prTrace = $jsonData["prTrace"]
  result.prLayout = $jsonData["prLayout"]
  result.erValX = $jsonData["erValX"]
  result.erValY = $jsonData["erValY"]


func createDataPacket*(p_mnist, p_pred: Plot, erVal: (float, float)): string =
  ## create a data packet based on the two `Plot` objects and the new
  ## error value `erVal`
  result = ""
  var dataTab = initOrderedTable[string, JsonNode](8)
  let
    prefixes = ["mn", "pr"]
    plots = [p_mnist, p_pred]
  for tup in zip(plots, prefixes):
    let (p, prefix) = tup
    dataTab[&"{prefix}Trace"] = % p.traces[0]
    dataTab[&"{prefix}Layout"] = % p.layout
  dataTab["erValX"] = % erVal[0]
  dataTab["erValY"] = % erVal[1]
  let jsonObj = JsonNode(kind: JObject, fields: dataTab)
  result.toUgly(jsonObj)

proc preparePlotly*(width: int): (Plot[float32], Plot[float32], Plot[float32]) =
  ## convenience proc which prepares Plotly, i.e. creates all `Plot` objects
  ## to be used on server and client side

  let
    mnist = Trace[float32](mode: PlotMode.LinesMarkers, `type`: PlotType.HeatMap)
    prediction = Trace[float32](mode: PlotMode.LinesMarkers, `type`: PlotType.HeatMap)
    error = Trace[float32](mode: PlotMode.LinesMarkers, `type`: PlotType.Scatter)

  mnist.colormap = ColorMap.Viridis
  prediction.colormap = ColorMap.Viridis
  # initialize data with 0
  mnist.zs = newSeqWith(28, newSeq[float32](28))
  # some start values for prediction
  prediction.zs = mapIt(toSeq(0 .. 10), @[random(1.0).float32])

  error.marker = Marker[float32](size: @[10.0.float32], color: @[Color(r: 0.9, g: 0.4, b: 0.0, a: 1.0)])

  # NOTE: for certain sizes too small, the pred width will be screwed up
  let pred_width = int(width / 4)
  let
    layout_mnist = Layout(title: &"MNIST example: label {0}", width: width, height: width,
                          xaxis: Axis(title: "my x-axis"),
                          yaxis: Axis(title: "y-axis too"), autosize: false)
    layout_pred = Layout(title: &"label {0}", width: pred_width, height: width,
                         xaxis: Axis(title: ""),
                         yaxis: Axis(title: "prob digit"), autosize: false)
    layout_error = Layout(title: &"Traning accuracy", width: width, height: width,
                         xaxis: Axis(title: "Training epoch"),
                         yaxis: Axis(title: "Accuracy"), autosize: false)
    p_mnist = Plot[float32](layout: layout_mnist, traces: @[mnist])
    p_pred  = Plot[float32](layout: layout_pred, traces: @[prediction])
    p_error = Plot[float32](layout: layout_error, traces: @[error])
  result = (p_mnist, p_pred, p_error)
