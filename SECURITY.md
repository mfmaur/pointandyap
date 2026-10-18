# Security

Point and Yap records the screen, the microphone and the element under the cursor, so security and privacy reports
matter a lot here.

## What it does with data

- Recordings stay on your Mac in `~/PointAndYap/sessions`. The app uploads nothing; there is no account and no analytics. Its
  only network request is the update check at pointandyap.com/appcast.xml (Sparkle, no system profile).
- Speech is transcribed with Apple's on-device model.
- The MCP server (`PointAndYap --mcp`) is a local process that your coding agent starts. It only reads `~/PointAndYap/sessions` and
  writes the item states there. What an agent then sends to its own model provider is up to that agent.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting on this repository (Security, Report a
vulnerability). You will get an answer within a few days. Fixes are released as a new version with a note in the
changelog.
