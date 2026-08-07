$ErrorActionPreference = "Stop"

choco install mingw --no-progress -y
"C:\ProgramData\mingw64\mingw64\bin" | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
