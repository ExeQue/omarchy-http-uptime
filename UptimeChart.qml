import QtQuick
import qs.Commons
import qs.Ui

// Line chart per bucket on a fixed 0–100 % axis: uptime, plus the share of slow checks.
// buckets / slowBuckets: percentages as strings, oldest first; "" means no checks ran and breaks the line.
Item {
  id: chart

  property var buckets: []
  property var slowBuckets: []
  property color slowColor: Color.muted
  property int bucketSeconds: 3600
  property color urgent: Color.urgent
  property int hover: -1
  readonly property real axisWidth: Style.space(34)
  // Vertical inset so the 100 % and 0 % axis labels stay inside the chart.
  readonly property real inset: Style.font.caption

  implicitHeight: Style.space(72)

  function px(i) { return axisWidth + (buckets.length > 1 ? i * (width - axisWidth) / (buckets.length - 1) : 0) }
  function py(v) { return inset + (height - inset * 2) * (100 - v) / 100 }

  function label(i) {
    var hours = bucketSeconds / 3600
    var ago = buckets.length - 1 - i
    var span = hours < 24 ? (ago * hours) + "–" + ((ago + 1) * hours) + " h ago" : ago === 0 ? "Last 24 h" : (ago + 1) + " days ago"
    var pct = v => parseFloat(v).toFixed(v === "100.00" || v === "0.00" ? 0 : 2) + "%"
    var v = buckets[i]
    if (v === "") return span + ": no checks"
    return span + ": uptime " + pct(v) + (slowBuckets[i] ? ", slow " + pct(slowBuckets[i]) : "")
  }

  onBucketsChanged: plot.requestPaint()
  onSlowBucketsChanged: plot.requestPaint()
  onWidthChanged: plot.requestPaint()
  onHeightChanged: plot.requestPaint()
  onHoverChanged: plot.requestPaint()

  Text {
    y: chart.py(100) - height / 2
    textFormat: Text.PlainText
    text: "100%"
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    y: chart.py(0) - height / 2
    textFormat: Text.PlainText
    text: "0%"
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Canvas {
    id: plot
    anchors.fill: parent
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var b = chart.buckets

      ctx.strokeStyle = Qt.rgba(Color.muted.r, Color.muted.g, Color.muted.b, 0.35)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(chart.axisWidth, chart.py(100))
      ctx.lineTo(width, chart.py(100))
      ctx.moveTo(chart.axisWidth, chart.py(0))
      ctx.lineTo(width, chart.py(0))
      ctx.stroke()

      function line(values, color) {
        ctx.strokeStyle = color
        ctx.lineWidth = Style.space(2)
        ctx.lineJoin = "round"
        ctx.beginPath()
        var drawing = false
        for (var j = 0; j < values.length; j++) {
          if (values[j] === "" || values[j] === undefined) { drawing = false; continue }
          var x = chart.px(j), y = chart.py(parseFloat(values[j]))
          if (drawing) ctx.lineTo(x, y)
          else ctx.moveTo(x, y)
          drawing = true
        }
        ctx.stroke()
        // A point with no neighbours has no segment to draw, so mark it with a dot.
        ctx.fillStyle = color
        for (j = 0; j < values.length; j++) {
          var has = k => values[k] !== undefined && values[k] !== ""
          if (!has(j) || has(j - 1) || has(j + 1)) continue
          ctx.beginPath()
          ctx.arc(chart.px(j), chart.py(parseFloat(values[j])), Style.space(2), 0, 2 * Math.PI)
          ctx.fill()
        }
      }
      // Slow on top: it is the anomaly, and at 100 % slow the two lines overlap.
      line(b, Color.foreground)
      line(chart.slowBuckets, chart.slowColor)
      var i

      for (i = 0; i < b.length; i++) {
        if (b[i] === "") continue
        var below = parseFloat(b[i]) < 100
        if (!below && i !== chart.hover) continue
        ctx.fillStyle = below ? chart.urgent : Color.foreground
        ctx.beginPath()
        ctx.arc(chart.px(i), chart.py(parseFloat(b[i])), Style.space(i === chart.hover ? 4 : 2.5), 0, 2 * Math.PI)
        ctx.fill()
      }

      if (chart.hover >= 0) {
        ctx.strokeStyle = Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(chart.px(chart.hover), 0)
        ctx.lineTo(chart.px(chart.hover), height)
        ctx.stroke()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    anchors.leftMargin: chart.axisWidth
    hoverEnabled: true
    onPositionChanged: function(mouse) {
      var n = chart.buckets.length
      chart.hover = n > 1 ? Math.round(mouse.x / (width / (n - 1))) : n - 1
    }
    onExited: chart.hover = -1
  }

  PanelToolTip {
    visible: chart.hover >= 0 && chart.hover < chart.buckets.length
    text: visible ? chart.label(chart.hover) : ""
    fontFamily: Style.font.family
  }
}
