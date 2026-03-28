import std/[os, strutils, times]

var logFile: File = nil
var quietMode* = false  # Set to true to suppress console output

proc getLogPath(): string =
  let homeDir = getHomeDir()
  let logDir = homeDir / ".minlsp"
  if not dirExists(logDir):
    try:
      createDir(logDir)
    except:
      discard
  result = logDir / "minlsp.log"

proc initLogFile() =
  if logFile == nil:
    let logPath = getLogPath()
    try:
      logFile = open(logPath, fmAppend)
      logFile.writeLine("\n--- minlsp started at ", $now(), " ---")
      logFile.flushFile()
    except:
      stderr.writeLine("Failed to open log file: ", getCurrentExceptionMsg())

proc errorLog*(args: varargs[string]) =
  initLogFile()
  let msg = args.join("")
  if logFile != nil:
    logFile.writeLine("[ERROR] ", msg)
    logFile.flushFile()
  stderr.writeLine(msg)

proc warnLog*(args: varargs[string]) =
  initLogFile()
  let msg = args.join("")
  if logFile != nil:
    logFile.writeLine("[WARN] ", msg)
    logFile.flushFile()

proc debugLog*(args: varargs[string]) =
  initLogFile()
  let msg = args.join("")
  if logFile != nil:
    logFile.writeLine("[DEBUG] ", msg)
    logFile.flushFile()

proc infoLog*(args: varargs[string]) =
  initLogFile()
  let msg = args.join("")
  if logFile != nil:
    logFile.writeLine("[INFO] ", msg)
    logFile.flushFile()
  if not quietMode:
    stderr.writeLine(msg)
