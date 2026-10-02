import std/[os, strutils, unittest]
import threecode/search

let logA = """
session 2026-01-01T00:00:00+00:00 profile=p.m cwd=/home/u/alpha
user
  hello zebra world
assistant
  the ZEBRA says hi
tool_result
  tab	separated	zebra	line

session 2026-01-02T00:00:00+00:00 profile=p.m cwd=/home/u/beta
user
  second record body
"""

proc writeLog(path, body: string) =
  createDir(path.parentDir)
  writeFile(path, body)

suite "search: term normalization":
  test "lowercases and collapses whitespace":
    check normalizeTerm("Foo   BAR") == "foo bar"
    check normalizeTerm("\ttab\tand\tspaces  ") == "tab and spaces"
    check normalizeTerm("   ") == ""
    check normalizeTerm("already") == "already"

suite "search: mapString":
  test "extracts the newest cwd and blanks header text":
    let m = mapString(logA)
    check m.cwd == "/home/u/beta"          # last session header wins
    check m.low.find("profile=p.m") < 0    # header args never match
    check m.low.find("cwd=/home") < 0
    check "hello zebra world" in m.low     # body text lowered, not blanked
    check "the zebra says hi" in m.low
    check m.lineStart.len == 12

suite "search: counting":
  test "single word is case-insensitive with count and first offset":
    let m = mapString(logA)
    let (n, first, len) = countTerm(m.low, @["zebra"])
    check n == 3
    check len == 5
    check m.low[first ..< first + 5] == "zebra"

  test "phrase matches across whitespace runs and line breaks":
    let m = mapString("user\n  wrap the\n      zebra tail here\n")
    check countTerm(m.low, @["the", "zebra"]).count == 1
    check countTerm(m.low, @["zebra", "tail"]).count == 1
    check countTerm(m.low, @["the", "zebra", "tail"]).count == 1

  test "phrase needs whitespace between words":
    let m = mapString("user\n  foobar baz\n")
    check countTerm(m.low, @["foo", "bar"]).count == 0
    check countTerm(m.low, @["foo", "baz"]).count == 0

  test "roles and tool names in headers do not match":
    let m = mapString("tool bash id=1\n  ran a command\n")
    check countTerm(m.low, @["bash"]).count == 0
    check countTerm(m.low, @["command"]).count == 1

suite "search: ranking":
  test "frequency first, then newest":
    let dir = getTempDir() / ("3code-search-rank-" & $getCurrentProcessId())
    removeDir(dir)
    defer: removeDir(dir)
    # Paths arrive newest-first, like listSessionPaths.
    writeLog(dir / "b.3log", "user\n  once\n")
    writeLog(dir / "a.3log", "user\n  once twice\n  once\n")
    writeLog(dir / "c.3log", "user\n  once\n")
    let hits = searchSessions(@[dir / "b.3log", dir / "a.3log", dir / "c.3log"],
                              @["once"])
    check hits.len == 3
    check extractFilename(hits[0].path) == "a.3log"
    check hits[0].score == 2
    check extractFilename(hits[1].path) == "b.3log"  # tie: newest wins
    check extractFilename(hits[2].path) == "c.3log"
    check hits[0].cwd == ""

suite "search: snippets":
  test "strips 3log formatting and windows around the match":
    let f = getTempDir() / ("3code-search-snip-" & $getCurrentProcessId() & ".3log")
    writeLog(f, "user\n  prefix text the match sits here and a long tail " &
                "runs well past the display window\n")
    defer: removeFile(f)
    let hits = searchSessions(@[f], @["match"])
    check hits.len == 1
    let s = hitSnippet(hits[0], 40)
    check "the match sits" in s
    check "prefix" notin s
    check s.endsWith("…")
    check s.startsWith("…")

  test "phrase snippet joins the lines it spans":
    let f = getTempDir() / ("3code-search-span-" & $getCurrentProcessId() & ".3log")
    writeLog(f, "user\n  alpha\n  bravo charlie\n")
    defer: removeFile(f)
    let hits = searchSessions(@[f], @["bravo", "charlie"])
    check hits.len == 1
    check "bravo charlie" in hitSnippet(hits[0], 60)

  test "unreadable and empty files are skipped":
    let dir = getTempDir() / ("3code-search-empty-" & $getCurrentProcessId())
    removeDir(dir)
    defer: removeDir(dir)
    createDir(dir)
    writeLog(dir / "x.3log", "")
    writeLog(dir / "y.3log", "session\n")
    check searchSessions(@[dir / "x.3log", dir / "y.3log", dir / "gone.3log"],
                         @["anything"]).len == 0
