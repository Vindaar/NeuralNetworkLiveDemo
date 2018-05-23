import plotly
import sequtils
import strutils, strformat
import tables
import chroma
import jsffi
import dom
import json
import jswebsockets

var
  socket = newWebSocket("ws://localhost:8080")

proc parseNewData(data: cstring): (JsObject, JsObject) =
  let jsonData = ($data).parseJson
  let
    trace = jsonData["trace"]
    layoutN = jsonData["layout"]
  result[0] = parseJsonToJs("[" & pretty(trace) & "]")
  result[1] = parseJsonToJs(pretty(layoutN))

proc animateClient(p: Plot) =
  let
    # call `json` for each element of `Plot.datas`
    jsons = mapIt(p.datas, it.json(as_pretty = false))
    #data_string = mapIt(jsons, toJs(it))
    data_string = parseJsonToJs("[" & join(jsons, ",") & "]")
    #layout_Js = toJs("[" & pretty(% p.layout) & "]")
    layout_Js = parseJsonToJs(pretty(% p.layout))

  Plotly.newPlot("lineplot", data_string, layout_Js)
  proc doAgain() =
    socket.send("ping")
    socket.onMessage = proc (e: MessageEvent) =
      echo("received: ", e.data)
      let layout = layout_Js
      let (newData, newLayout) = parseNewData(e.data)
      # replace data with new data
      Plotly.react("lineplot", newData, newLayout)

  discard window.setInterval(doAgain, 500)

proc main() =

  socket.onOpen = proc (e:Event) =
    echo("sent: test")
    socket.send("test")
  let
    d = Trace[float](mode: PlotMode.LinesMarkers, `type`: PlotType.HeatMap)
  d.colormap = ColorMap.Viridis
  # initialize data with 0
  d.zs = newSeqWith(28, newSeq[float](28))

  let
    layout = Layout(title: &"MNIST example: label {0}", width: 800, height: 800,
                    xaxis: Axis(title: "my x-axis"),
                    yaxis: Axis(title: "y-axis too"), autosize: false)
    p = Plot[float](layout: layout, datas: @[d])
  # now animate the plots
  p.animateClient()

  # when done, close...
  socket.onClose = proc (e:CloseEvent) =
    echo("closing: ",e.reason)


when isMainModule:
  main()
