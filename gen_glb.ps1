# Generate a minimal valid GLB 2.0 file with a triangle
# GLB format: Header(12) + JSON chunk(8 + json) + BIN chunk(8 + bin)

# 1. Build glTF JSON (no data URIs, uses BIN chunk)
$gltf = @{
    asset = @{ version = "2.0"; generator = "test" }
    scene = 0
    scenes = @(@{ nodes = @(0) })
    nodes = @(@{ mesh = 0; name = "Triangle" })
    meshes = @(@{ primitives = @(@{ attributes = @{ POSITION = 0 }; indices = 1; material = 0 }) })
    materials = @(@{ pbrMetallicRoughness = @{ baseColorFactor = @(0.8, 0.2, 0.2, 1.0); metallicFactor = 0.0; roughnessFactor = 0.5 } })
    buffers = @(@{ byteLength = 44 })
    bufferViews = @(
        @{ buffer = 0; byteOffset = 0; byteLength = 36; target = 34962 },
        @{ buffer = 0; byteOffset = 36; byteLength = 6; target = 34963 }
    )
    accessors = @(
        @{ bufferView = 0; byteOffset = 0; componentType = 5126; count = 3; type = "VEC3"; max = @(1.0, 1.0, 0.0); min = @(-1.0, -1.0, 0.0) },
        @{ bufferView = 1; byteOffset = 0; componentType = 5123; count = 3; type = "SCALAR" }
    )
}

$jsonStr = $gltf | ConvertTo-Json -Compress -Depth 10
$jsonUtf8 = [System.Text.Encoding]::UTF8.GetBytes($jsonStr)

# Pad JSON to 4-byte alignment with spaces (0x20)
$jsonPadding = (4 - ($jsonUtf8.Length % 4)) % 4
$jsonPadded = New-Object byte[] ($jsonUtf8.Length + $jsonPadding)
[Array]::Copy($jsonUtf8, 0, $jsonPadded, 0, $jsonUtf8.Length)
for ($i = $jsonUtf8.Length; $i -lt $jsonPadded.Length; $i++) {
    $jsonPadded[$i] = 0x20
}

# 2. Build BIN data
# 3 vertices (VEC3 FLOAT): v0=(0,1,0), v1=(-1,-1,0), v2=(1,-1,0)
$vertices = @(
    0.0, 1.0, 0.0,
    -1.0, -1.0, 0.0,
    1.0, -1.0, 0.0
)
$vertexArr = New-Object byte[] 36
$vidx = 0
foreach ($v in $vertices) {
    $bytes = [BitConverter]::GetBytes([Single]$v)
    [Array]::Copy($bytes, 0, $vertexArr, $vidx, 4)
    $vidx += 4
}

# 3 indices (UNSIGNED SHORT): 0, 1, 2
$indices = @(0, 1, 2)
$indexArr = New-Object byte[] 6
$iidx = 0
foreach ($i in $indices) {
    $bytes = [BitConverter]::GetBytes([UInt16]$i)
    [Array]::Copy($bytes, 0, $indexArr, $iidx, 2)
    $iidx += 2
}

# Combine BIN data (36 + 6 = 42, pad to 44 for 4-byte alignment)
$binPadded = New-Object byte[] 44
[Array]::Copy($vertexArr, 0, $binPadded, 0, 36)
[Array]::Copy($indexArr, 0, $binPadded, 36, 6)
# last 2 bytes already 0x00

# 3. Build GLB using MemoryStream with BinaryWriter (flush properly)
$totalLength = 12 + 8 + $jsonPadded.Length + 8 + $binPadded.Length

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)

# Header
$bw.Write([UInt32]0x46546C67)       # magic "glTF"
$bw.Write([UInt32]2)                # version
$bw.Write([UInt32]$totalLength)     # length

# JSON chunk
$bw.Write([UInt32]$jsonPadded.Length)  # chunk length
$bw.Write([UInt32]0x4E4F534A)          # chunk type "JSON"
$bw.Write($jsonPadded)

# BIN chunk
$bw.Write([UInt32]$binPadded.Length)   # chunk length
$bw.Write([UInt32]0x004E4942)          # chunk type "BIN\0"
$bw.Write($binPadded)

$bw.Flush()
$glbBytes = $ms.ToArray()
$bw.Close()
$ms.Close()

# Write to file
$outPath = "D:\DevEco_studio\ArkTavern\test_model.glb"
[System.IO.File]::WriteAllBytes($outPath, $glbBytes)

# Also copy to rawfile
$rawfilePath = "d:\DevEco_studio\ArkTavern\entry\src\main\resources\rawfile\test_model.glb"
[System.IO.File]::WriteAllBytes($rawfilePath, $glbBytes)

Write-Host "Generated GLB file:"
Write-Host "  Path: $outPath"
Write-Host "  Actual size: $($glbBytes.Length) bytes"
Write-Host "  JSON chunk: $($jsonPadded.Length) bytes"
Write-Host "  BIN chunk: $($binPadded.Length) bytes"
Write-Host "  Total length field: $totalLength bytes"
Write-Host ""
Write-Host "JSON content:"
Write-Host $jsonStr
