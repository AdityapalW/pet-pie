#!/bin/zsh
# Packs the extension into pi-companion.vsix (no npm/vsce needed) and installs it into Antigravity IDE.
set -e
cd "$(dirname "$0")"
VERSION=$(python3 -c "import json;print(json.load(open('package.json'))['version'])")
STAGE=$(mktemp -d)
mkdir -p "$STAGE/extension"
cp package.json extension.js README.md "$STAGE/extension/"

cat > "$STAGE/[Content_Types].xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension=".json" ContentType="application/json"/><Default Extension=".js" ContentType="application/javascript"/><Default Extension=".md" ContentType="text/markdown"/><Default Extension=".vsixmanifest" ContentType="text/xml"/></Types>
XML

cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="pi-companion" Version="$VERSION" Publisher="local-hackathon"/>
    <DisplayName>Pi Companion</DisplayName>
    <Description xml:space="preserve">Connects Antigravity to Pi, your desktop pet.</Description>
    <Categories>Other</Categories>
    <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/></Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>
XML

rm -f pi-companion.vsix
(cd "$STAGE" && zip -qr "$OLDPWD/pi-companion.vsix" "[Content_Types].xml" extension.vsixmanifest extension)
rm -rf "$STAGE"
echo "Packed pi-companion.vsix"

CLI="/Applications/Antigravity IDE.app/Contents/Resources/app/bin/antigravity-ide"
if [[ "$1" == "--install" ]]; then
  "$CLI" --install-extension pi-companion.vsix --force
fi
