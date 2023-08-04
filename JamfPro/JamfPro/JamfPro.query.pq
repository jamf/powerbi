// Use this file to write queries to test your data connector
let
    result = JamfPro.Contents("https://jps.comcast.com:8443", "UAPI")
in
    result