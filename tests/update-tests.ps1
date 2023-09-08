$current_dir = Get-Location

Set-Location -Path ${PSScriptRoot}
./VhdlCommentParser.exe 'tb.csv'

Copy-Item './tb.csv' '../src/alu/'
Copy-Item './tb-inputs.txt' '../src/alu/'
Copy-Item './tb-expected.txt' '../src/alu/'
Copy-Item './command_lut.json' '../src/alu/'

Set-Location ${current_dir}