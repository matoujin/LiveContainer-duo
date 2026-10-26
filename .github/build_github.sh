#!/bin/sh
set -e

# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# Re-sign a Mach-O while preserving its existing entitlements.
# NEVER use `ldid -S""` on LiveContainer host binaries — that wipes
# com.apple.security.application-groups and causes SideStore installs to
# crash at launch (nil App Group path → fileURLWithPath:).
resign_preserve_ents() {
  bin="$1"
  ent_xml="${bin}.ent.xml"
  # Skip non-Mach-O quietly
  if ! file "$bin" | grep -q 'Mach-O'; then
    return 0
  fi
  case "$bin" in
    *LiveWidgetExtension)
      ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml "$bin" || true
      return 0
      ;;
  esac
  # Export current entitlements; skip resign if export fails / empty
  if ! ldid -e "$bin" > "$ent_xml" 2>/dev/null; then
    rm -f "$ent_xml"
    echo "warn: skip resign (ldid -e failed): $bin" >&2
    return 0
  fi
  if [ ! -s "$ent_xml" ]; then
    # Binary had no entitlements blob — leave signature alone rather than
    # blank-signing (which would also strip future SideStore templates).
    rm -f "$ent_xml"
    echo "warn: skip resign (empty entitlements): $bin" >&2
    return 0
  fi
  ldid -S"$ent_xml" "$bin" || echo "warn: ldid -S preserve failed: $bin" >&2
  rm -f "$ent_xml"
}

resign_app_machos() {
  root="$1"
  find "$root" -type f \( -perm -111 -o -name '*.dylib' \) ! -path '*/_CodeSignature/*' | while read -r bin; do
    resign_preserve_ents "$bin"
  done
}

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# Stamp host LiveContainer.app for iPhone Duo / iOS 27.1 before packaging standalone IPA
python3 .github/patch_duo_sdk.py Payload/LiveContainer.app
# Refresh CodeDirectory after Mach-O / Info.plist edits — keep original entitlements
resign_app_machos Payload/LiveContainer.app

# temporarily move sidestore support framrwork to tmp before zip
mkdir -p tmp
mv Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework ./tmp

# Standalone LiveContainer (Duo)
zip -r "LiveContainer_duo_ios27.1.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
# Keep legacy artifact name for existing nightly consumers
cp -f "LiveContainer_duo_ios27.1.ipa" "$scheme.ipa"

mv ./tmp/SideStoreSupport.framework Payload/LiveContainer.app/Frameworks

# put sidestore related keys into Info.plist and settings bundle
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups array' ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups:0 string group.com.SideStore.SideStore' ./Payload/LiveContainer.app/Info.plist || \
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' ./Payload/LiveContainer.app/Info.plist || true

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1 dict" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2 dict" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer" ./Payload/LiveContainer.app/Info.plist || true

/usr/libexec/PlistBuddy -c "Add :INIntentsSupported array" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist || true
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist || true

/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" ./Payload/LiveContainer.app/Settings.bundle/Root.plist || true
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist || true
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist || true
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" ./Payload/LiveContainer.app/Settings.bundle/Root.plist || true

# download SideStore
cd tmp
wget https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa
unzip -o SideStore.ipa
cd ..

# SideStore
mv ./tmp/Payload/SideStore.app ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
# Export SideStore entitlements BEFORE dylibify (never blank-sign host or SideStore).
SIDE_ENT="./tmp/SideStore.ent.xml"
ldid -e ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore > "$SIDE_ENT" 2>/dev/null || true
./dylibify ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib
rm ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
if [ -s "$SIDE_ENT" ]; then
  ldid -S"$SIDE_ENT" ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
else
  # No entitlements blob to restore — pseudo-sign without injecting empty ents.
  ldid -s ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore || true
fi
rm -f "$SIDE_ENT"
cp ./.github/sidelc/LCAppInfo.plist ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/

# copy intents
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Intents.intentdefinition ./Payload/LiveContainer.app/
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition ./Payload/LiveContainer.app/
cp -r ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Metadata.appintents ./Payload/LiveContainer.app/Metadata.appintents
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata

# AltWidgetExtension
mkdir -p ./Payload/LiveContainer.app/PlugIns
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LiveWidgetExtension"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
mv ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Sign
rm -rf .zsign_cache
find Payload -type d -name "_CodeSignature" -exec rm -rf {} + 2>/dev/null || true

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Stamp entire payload again (host + SideStoreApp.framework + PlugIns/*.appex + Frameworks)
python3 .github/patch_duo_sdk.py Payload/LiveContainer.app

# Ad-hoc resign after Duo SDK / Mach-O stamp — preserve host entitlements.
# Never blank-sign (`ldid -S""`). LiveWidgetExtension uses adhoc xml with application-groups.
resign_app_machos Payload/LiveContainer.app

# package Duo + SideStore
zip -r "LiveContainer+SideStore_duo_ios27.1.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
cp -f "LiveContainer+SideStore_duo_ios27.1.ipa" "$scheme+SideStore.ipa"

ls -lh LiveContainer*_duo_ios27.1.ipa "$scheme.ipa" "$scheme+SideStore.ipa"
