# Parse layout JSON and extract all text nodes with bounds
param(
    [string]$Path = 'D:\DevEco_studio\ArkTavern\layout_settings.json'
)
$j = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json

$results = New-Object System.Collections.ArrayList

function FindNode($n) {
    $text = $n.attributes.text
    $bounds = $n.attributes.bounds
    $type = $n.attributes.type
    $clickable = $n.attributes.clickable
    $origText = $n.attributes.originalText
    if (($text -and $text -ne '') -or ($origText -and $origText -ne '')) {
        $results.Add([PSCustomObject]@{
            text = if ($text) { $text } else { $origText }
            bounds = $bounds
            type = $type
            clickable = $clickable
        }) | Out-Null
    }
    if ($n.children) {
        foreach ($c in $n.children) {
            FindNode $c
        }
    }
}
FindNode $j

Write-Host "=== All text nodes ( $($results.Count) total ) ==="
$results | ForEach-Object {
    Write-Host ("text='{0}' bounds={1} type={2} clickable={3}" -f $_.text, $_.bounds, $_.type, $_.clickable)
}
