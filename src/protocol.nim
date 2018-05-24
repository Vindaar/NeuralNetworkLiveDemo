import plotly
import chroma
import json, tables, sequtils, random, strformat

type
  DataPacket* = object
    mnTrace*: string
    mnLayout*: string
    prTrace*: string
    prLayout*: string
    erVal*: string

  DataParsingError* = object of Exception

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
  result.erVal = $jsonData["erVal"]

func createDataPacket*(p_mnist, p_pred: Plot, erVal: float): string =
  ## create a data packet based on the two `Plot` objects and the new
  ## error value `erVal`
  result = ""
  var dataTab = initOrderedTable[string, JsonNode](8)
  let
    prefixes = ["mn", "pr"]
    plots = [p_mnist, p_pred]
  for tup in zip(plots, prefixes):
    let (p, prefix) = tup
    dataTab[&"{prefix}Trace"] = % p.datas[0]
    dataTab[&"{prefix}Layout"] = % p.layout
  dataTab["erVal"] = % erVal
  let jsonObj = JsonNode(kind: JObject, fields: dataTab)
  result.toUgly(jsonObj)

proc preparePlotly*(): (Plot[float], Plot[float], Plot[float]) =
  ## convenience proc which prepares Plotly, i.e. creates all `Plot` objects
  ## to be used on server and client side
  let
    mnist = Trace[float](mode: PlotMode.LinesMarkers, `type`: PlotType.HeatMap)
    prediction = Trace[float](mode: PlotMode.LinesMarkers, `type`: PlotType.HeatMap)
    error = Trace[float](mode: PlotMode.LinesMarkers, `type`: PlotType.Scatter)

  mnist.colormap = ColorMap.Viridis
  prediction.colormap = ColorMap.Viridis
  # initialize data with 0
  mnist.zs = newSeqWith(28, newSeq[float](28))
  # some start values for prediction
  prediction.zs = mapIt(toSeq(0 .. 10), @[random(1.0)])

  error.marker = Marker[float](size: @[10.0], color: @[Color(r: 0.9, g: 0.4, b: 0.0, a: 1.0)])
  # TODO: replace data...
  error.xs = @[1'f64, 2, 3, 4, 5]
  error.ys = @[1'f64, 2, 1, 9, 5]

  let
    layout_mnist = Layout(title: &"MNIST example: label {0}", width: 800, height: 800,
                          xaxis: Axis(title: "my x-axis"),
                          yaxis: Axis(title: "y-axis too"), autosize: false)
    layout_pred = Layout(title: &"MNIST prediction: label {0}", width: 200, height: 800,
                         xaxis: Axis(title: ""),
                         yaxis: Axis(title: "prob digit"), autosize: false)
    layout_error = Layout(title: &"Traning error", width: 800, height: 800,
                         xaxis: Axis(title: "Training epoch"),
                         yaxis: Axis(title: "Error rate"), autosize: false)
    p_mnist = Plot[float](layout: layout_mnist, datas: @[mnist])
    p_pred  = Plot[float](layout: layout_pred, datas: @[prediction])
    p_error = Plot[float](layout: layout_error, datas: @[error])
  result = (p_mnist, p_pred, p_error)
