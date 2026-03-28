discard """
  exitcode: 0
"""

import std/[unittest, json, streams, strutils]
import minlsp/baseprotocol
import minlsp/logger

# Suppress log output during tests
quietMode = true

# LSP Protocol Tests

block create_response_with_int_id:
  let result = %*{"capabilities": {"textDocumentSync": 1}}
  let response = createResponse(%1, result)
  
  doAssert response["jsonrpc"].getStr == "2.0"
  doAssert response["id"].getInt == 1
  doAssert response["result"]["capabilities"]["textDocumentSync"].getInt == 1

block create_response_with_string_id:
  let result = %*{"capabilities": {"textDocumentSync": 1}}
  let response = createResponse(%"abc123", result)
  
  doAssert response["jsonrpc"].getStr == "2.0"
  doAssert response["id"].getStr == "abc123"
  doAssert response["result"]["capabilities"]["textDocumentSync"].getInt == 1

block create_error_response_with_int_id:
  let errorResponse = createErrorResponse(%1, -32601, "Method not found")
  
  doAssert errorResponse["jsonrpc"].getStr == "2.0"
  doAssert errorResponse["id"].getInt == 1
  doAssert errorResponse["error"]["code"].getInt == -32601
  doAssert errorResponse["error"]["message"].getStr == "Method not found"

block create_error_response_with_string_id:
  let errorResponse = createErrorResponse(%"req-1", -32601, "Method not found")
  
  doAssert errorResponse["jsonrpc"].getStr == "2.0"
  doAssert errorResponse["id"].getStr == "req-1"
  doAssert errorResponse["error"]["code"].getInt == -32601
  doAssert errorResponse["error"]["message"].getStr == "Method not found"

block form_frame_creates_correct_lsp_frame:
  let data = %*{"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {}}}
  let frame = formFrame(data)
  
  doAssert frame.startsWith("Content-Length:")
  doAssert frame.contains("\r\n\r\n")
  doAssert frame.contains(""""jsonrpc":"2.0""" )

block form_frame_includes_correct_content_length:
  let data = %*{"jsonrpc": "2.0", "id": 1, "result": nil}
  let frame = formFrame(data)
  
  # Extract the content length
  let headerEnd = frame.find("\r\n\r\n")
  doAssert headerEnd > 0
  
  let header = frame[0..<headerEnd]
  let contentStart = headerEnd + 4
  let content = frame[contentStart..^1]
  
  # The Content-Length header should match actual content length
  let contentLenStr = header.split("Content-Length: ")[1]
  let declaredLen = parseInt(contentLenStr)
  doAssert declaredLen == content.len

# URI Conversion Tests

block uri_to_path_conversion_unix:
  doAssert uriToPath("file:///home/user/test.nim") == "/home/user/test.nim"
  doAssert uriToPath("file:///tmp/project/main.nim") == "/tmp/project/main.nim"

block uri_to_path_conversion_no_prefix:
  doAssert uriToPath("/home/user/test.nim") == "/home/user/test.nim"

block path_to_uri_conversion_unix:
  when not defined(windows):
    doAssert pathToUri("/home/user/test.nim") == "file:///home/user/test.nim"

block path_to_uri_roundtrip:
  let originalPath = "/home/user/test.nim"
  let uri = pathToUri(originalPath)
  let convertedPath = uriToPath(uri)
  doAssert convertedPath == originalPath

# Frame Read/Write Tests (Stream)

block send_frame_to_stream:
  let data = %*{"jsonrpc": "2.0", "id": 1, "result": {}}
  let frame = formFrame(data)
  
  var ss = newStringStream()
  ss.sendFrame(frame)
  ss.setPosition(0)
  
  let content = ss.readAll()
  doAssert content.startsWith("Content-Length:")
  doAssert content.contains("\r\n\r\n")

block send_json_to_stream:
  let data = %*{"jsonrpc": "2.0", "id": 1, "result": {"key": "value"}}
  
  var ss = newStringStream()
  ss.sendJson(data)
  ss.setPosition(0)
  
  let content = ss.readAll()
  doAssert content.startsWith("Content-Length:")
  doAssert content.contains(""""key":"value""" )

block read_frame_from_stream:
  let jsonContent = """{"jsonrpc":"2.0","id":1,"result":{}}"""
  let frame = "Content-Length: " & $jsonContent.len & "\r\n\r\n" & jsonContent
  
  var ss = newStringStream(frame)
  let readContent = ss.readFrame()
  
  doAssert readContent == jsonContent

block read_frame_with_extra_headers:
  let jsonContent = """{"jsonrpc":"2.0","id":1,"result":{}}"""
  let frame = "Content-Length: " & $jsonContent.len & "\r\n" &
              "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" &
              "\r\n" & jsonContent
  
  var ss = newStringStream(frame)
  let readContent = ss.readFrame()
  
  doAssert readContent == jsonContent

block read_complex_json_frame:
  let jsonContent = """{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootPath":"/tmp"}}"""
  let frame = "Content-Length: " & $jsonContent.len & "\r\n\r\n" & jsonContent
  
  var ss = newStringStream(frame)
  let readContent = ss.readFrame()
  let parsed = parseJson(readContent)
  
  doAssert parsed["jsonrpc"].getStr == "2.0"
  doAssert parsed["id"].getInt == 1
  doAssert parsed["method"].getStr == "initialize"
  doAssert parsed["params"]["rootPath"].getStr == "/tmp"

# Error Handling Tests

block malformed_frame_missing_content_length:
  let frame = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}"
  var ss = newStringStream(frame)
  
  try:
    discard ss.readFrame()
    doAssert false, "Expected MalformedFrame exception"
  except MalformedFrame:
    discard

block malformed_frame_invalid_header_line:
  let frame = "InvalidHeaderLine\r\n\r\n{}"
  var ss = newStringStream(frame)
  
  try:
    discard ss.readFrame()
    doAssert false, "Expected MalformedFrame exception"
  except MalformedFrame:
    discard

block malformed_frame_invalid_content_length:
  let frame = "Content-Length: abc\r\n\r\n{}"
  var ss = newStringStream(frame)
  
  try:
    discard ss.readFrame()
    doAssert false, "Expected MalformedFrame exception"
  except MalformedFrame:
    discard

block unsupported_encoding:
  let jsonContent = "{}"
  let frame = "Content-Length: " & $jsonContent.len & "\r\n" &
              "Content-Type: application/vscode-jsonrpc; charset=iso-8859-1\r\n" &
              "\r\n" & jsonContent
  var ss = newStringStream(frame)
  
  try:
    discard ss.readFrame()
    doAssert false, "Expected UnsupportedEncoding exception"
  except UnsupportedEncoding:
    discard

# Tests pass silently - only output on failure
