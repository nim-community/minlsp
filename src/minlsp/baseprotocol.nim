import std/[asyncdispatch, asyncfile, json, parseutils, streams, strformat,
            strutils]


type
  BaseProtocolError* = object of CatchableError

  MalformedFrame* = object of BaseProtocolError
  UnsupportedEncoding* = object of BaseProtocolError

proc uriToPath*(uri: string): string =
  if uri.startsWith("file://"):
    result = uri[7..^1]
  else:
    result = uri

  when defined(windows):
    if result.startsWith("/"):
      result = result[1..^1]

proc pathToUri*(path: string): string =
  result = "file://"
  when defined(windows):
    result.add("/")
  result.add(path)

proc skipWhitespace(x: string, pos: int): int =
  result = pos
  while result < x.len and x[result] in Whitespace:
    inc result

proc sendFrame*(s: Stream | AsyncFile, frame: string) {.multisync} =

  when s is Stream:
    s.write frame
    s.flush
  else:
    await s.write frame

proc formFrame*(data: JsonNode): string =
  var frame = newStringOfCap(1024)
  toUgly(frame, data)
  result = &"Content-Length: {frame.len}\r\n\r\n{frame}"

proc sendJson*(s: Stream | AsyncFile, data: JsonNode) {.multisync.} =
  let frame = formFrame(data)
  await s.sendFrame(frame)

proc readFrame*(s: Stream | AsyncFile): Future[string] {.multisync.} =
  var contentLen = -1
  var headerStarted = false
  var ln: string
  while true:
    ln = await s.readLine()
    if ln.len != 0:
      headerStarted = true
      let sep = ln.find(':')
      if sep == -1:
        raise newException(MalformedFrame, "invalid header line: " & ln)

      let valueStart = ln.skipWhitespace(sep + 1)

      case ln[0 ..< sep]
      of "Content-Type":
        if ln.find("utf-8", valueStart) == -1 and ln.find("utf8", valueStart) == -1:
          raise newException(UnsupportedEncoding, "only utf-8 is supported")
      of "Content-Length":
        if parseInt(ln, contentLen, valueStart) == 0:
          raise newException(MalformedFrame, "invalid Content-Length: " &
                                              ln.substr(valueStart))
      else:
        # Unrecognized headers are ignored
        discard

    elif not headerStarted:
      continue
    else:
    
      if contentLen != -1:
        when s is Stream:
          var buf = s.readStr(contentLen)
        else:
          var
            buf = newString(contentLen)
            head = 0
          while contentLen > 0:
            let bytesRead = await s.readBuffer(buf[head].addr, contentLen)
            if bytesRead == 0:
              raise newException(MalformedFrame, "Unexpected EOF")
            contentLen -= bytesRead
            head += bytesRead

        return buf
      else:
        raise newException(MalformedFrame, "missing Content-Length header")

proc createResponse*(id: JsonNode, responseResult: JsonNode): JsonNode =
  result = %*{
    "jsonrpc": "2.0",
    "id": id,
    "result": responseResult
  }

proc createErrorResponse*(id: JsonNode, code: int, message: string): JsonNode =
  result = %*{
    "jsonrpc": "2.0",
    "id": id,
    "error": {
      "code": code,
      "message": message
    }
  }

