# 使用生产页面、内存数据库和录音替身生成六套主题明暗预览。
param(
    # PNG 输出目录，默认位于客户端的构建产物目录。
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../build/notes-redesign-preview')
)
$ErrorActionPreference = 'Stop'
# 保存已有预览设置，脚本结束后恢复调用环境。
$previousPreviewDirectory = $env:OMNI_NOTES_PREVIEW
# 测试项目根目录，命令始终在客户端执行。
$clientDirectory = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $clientDirectory
try {
    $env:OMNI_NOTES_PREVIEW = [System.IO.Path]::GetFullPath($OutputDirectory)
    & flutter test test/features/notes/notes_page_test.dart
    if ($LASTEXITCODE -ne 0) { throw '笔记页面测试或预览失败。' }
    Write-Output "预览目录：$env:OMNI_NOTES_PREVIEW"
} finally {
    $env:OMNI_NOTES_PREVIEW = $previousPreviewDirectory
    Pop-Location
}
