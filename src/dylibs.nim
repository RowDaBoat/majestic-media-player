## Library file names for loadLib to try. On macOS each comes again under
## Homebrew's prefixes: dlopen searches only /usr/local/lib and /usr/lib for
## a bare name, so Apple silicon's /opt/homebrew/lib would go unseen.

proc libNames*(names: openArray[string]): seq[string] =
  result = @names
  when defined(macosx):
    for prefix in ["/opt/homebrew/lib/", "/usr/local/lib/"]:
      for n in names: result.add prefix & n
