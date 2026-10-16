#!/usr/bin/env python3
"""Generates Rekeep.xcodeproj (Mac app, iPhone/iPad app, Share extension).

Sources live in folder-synchronised groups, so adding a Swift file never requires regenerating.
Re-run only when targets or build settings change."""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEAM = "RMZ2B524CF"
VERSION = "1.0"
BUILD = "1"
APP_GROUP = "group.com.pedrumshokouhi.rekeep"

TARGETS = [
    dict(
        name="Rekeep", folders=["Mac", "Shared", "SharedApp"], product="Rekeep", type="app",
        bundle="com.pedrumshokouhi.rekeep",
        settings={
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "SDKROOT": "macosx",
            "SUPPORTED_PLATFORMS": "macosx",
            "CODE_SIGN_ENTITLEMENTS": "Mac/Rekeep.entitlements",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "ENABLE_APP_SANDBOX": "YES",
            "INFOPLIST_KEY_LSUIElement": "YES",
            "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
            "INFOPLIST_KEY_NSHumanReadableCopyright": "© 2026 Pedrum Shokouhi",
            "INFOPLIST_KEY_CFBundleDisplayName": "Rekeep",
            "COMBINE_HIDPI_IMAGES": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
        },
    ),
    dict(
        name="RekeepMobile", folders=["iOS/App", "Shared", "SharedApp", "iOS/KeyboardUI"], product="Rekeep", type="app",
        bundle="com.pedrumshokouhi.rekeep",
        embeds=["RekeepShare", "RekeepKeyboard"],
        settings={
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "CODE_SIGN_ENTITLEMENTS": "iOS/App/Rekeep.entitlements",
            "INFOPLIST_KEY_CFBundleDisplayName": "Rekeep",
            "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.productivity",
            "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
            "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
            "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
            "INFOPLIST_KEY_NSPhotoLibraryUsageDescription": "Rekeep imports the photos you choose so you can reuse them later.",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        },
    ),
    dict(
        name="RekeepShare", folders=["iOS/Share", "Shared"], product="RekeepShare", type="extension",
        bundle="com.pedrumshokouhi.rekeep.share",
        exceptions={"iOS/Share": ["Info.plist"]},
        settings={
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            "SDKROOT": "iphoneos",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "CODE_SIGN_ENTITLEMENTS": "iOS/Share/RekeepShare.entitlements",
            "INFOPLIST_FILE": "iOS/Share/Info.plist",
            "INFOPLIST_KEY_CFBundleDisplayName": "Rekeep",
            "SKIP_INSTALL": "YES",
            "APPLICATION_EXTENSION_API_ONLY": "YES",
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
        },
    ),
]

TARGETS.append(dict(
    name="RekeepKeyboard", folders=["iOS/Keyboard", "Shared", "iOS/KeyboardUI"], product="RekeepKeyboard", type="extension",
    bundle="com.pedrumshokouhi.rekeep.keyboard",
    exceptions={"iOS/Keyboard": ["Info.plist"]},
    settings={
        "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "CODE_SIGN_ENTITLEMENTS": "iOS/Keyboard/RekeepKeyboard.entitlements",
        "INFOPLIST_FILE": "iOS/Keyboard/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "Rekeep",
        "SKIP_INSTALL": "YES",
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
    },
))

PRODUCT_TYPES = {"app": "com.apple.product-type.application", "extension": "com.apple.product-type.app-extension", "unittest": "com.apple.product-type.bundle.unit-test"}
WRAPPERS = {"app": ("wrapper.application", ".app"), "extension": ("wrapper.app-extension", ".appex"), "unittest": ("wrapper.cfbundle", ".xctest")}

counter = [0x10]
def new():
    counter[0] += 1
    return f"BB{counter[0]:06X}00000000000000000"[:24]

def q(v):
    if isinstance(v, list):
        return "(\n" + "".join(f"\t\t\t\t\t{q(x)},\n" for x in v) + "\t\t\t\t)"
    s = str(v)
    if s.isdigit() or (s and all(c.isalnum() or c in "._/" for c in s) and not s[0].isdigit()):
        return s
    return '"' + s.replace('"', '\\"') + '"'

def block(d, indent="\t\t\t\t"):
    return "".join(f"{indent}{k} = {q(v)};\n" for k, v in sorted(d.items()))

sections = {}
def add(kind, text):
    sections.setdefault(kind, []).append(text)

project_id, main_group, products_group = new(), new(), new()
proj_cfg_list, proj_debug, proj_release = new(), new(), new()
pkg_ref = new()

common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "SWIFT_VERSION": "6.0", "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor", "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "MARKETING_VERSION": VERSION, "CURRENT_PROJECT_VERSION": BUILD, "DEVELOPMENT_TEAM": TEAM,
    "REKEEP_APP_GROUP": APP_GROUP,
}
debug_proj = dict(common, DEBUG_INFORMATION_FORMAT="dwarf", ENABLE_TESTABILITY="YES", GCC_OPTIMIZATION_LEVEL="0",
                  ONLY_ACTIVE_ARCH="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG $(inherited)",
                  SWIFT_OPTIMIZATION_LEVEL="-Onone", GCC_PREPROCESSOR_DEFINITIONS=["DEBUG=1", "$(inherited)"])
release_proj = dict(common, DEBUG_INFORMATION_FORMAT="dwarf-with-dsym", ENABLE_NS_ASSERTIONS="NO",
                    SWIFT_COMPILATION_MODE="wholemodule", VALIDATE_PRODUCT="YES")

# Shared folder groups (one synchronized group per folder, shared across targets).
folder_groups = {}
for t in TARGETS:
    for f in t["folders"]:
        if f not in folder_groups:
            folder_groups[f] = new()

target_ids = {}
product_refs = {}
for t in TARGETS:
    target_ids[t["name"]] = new()
    product_refs[t["name"]] = new()

exception_sets = {}  # (target, folder) -> id
for t in TARGETS:
    for folder, files in t.get("exceptions", {}).items():
        eid = new()
        exception_sets.setdefault(folder, []).append(eid)
        add("PBXFileSystemSynchronizedBuildFileExceptionSet",
            f"\t\t{eid} = {{\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n\t\t\tmembershipExceptions = (\n"
            + "".join(f"\t\t\t\t{q(x)},\n" for x in files) + f"\t\t\t);\n\t\t\ttarget = {target_ids[t['name']]};\n\t\t}};")

for folder, gid in folder_groups.items():
    exc = exception_sets.get(folder)
    exc_text = ("exceptions = (" + ", ".join(exc) + ", ); ") if exc else ""
    add("PBXFileSystemSynchronizedRootGroup",
        f"\t\t{gid} = {{isa = PBXFileSystemSynchronizedRootGroup; {exc_text}explicitFileTypes = {{}}; explicitFolders = (); path = {q(folder)}; sourceTree = \"<group>\"; }};")

for t in TARGETS:
    tid = target_ids[t["name"]]
    cfg_list, dbg, rel = new(), new(), new()
    src, fw, res = new(), new(), new()
    dep_pkg, bf_pkg = new(), new()
    product = product_refs[t["name"]]
    ftype, ext = WRAPPERS[t["type"]]
    phases = [src, fw, res]
    deps = []

    for embedded in t.get("embeds", []):
        copy, bf, dep, proxy = new(), new(), new(), new()
        add("PBXBuildFile", f"\t\t{bf} = {{isa = PBXBuildFile; fileRef = {product_refs[embedded]}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};")
        add("PBXCopyFilesBuildPhase", f"\t\t{copy} = {{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = ({bf}, ); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0; }};")
        add("PBXContainerItemProxy", f"\t\t{proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {target_ids[embedded]}; remoteInfo = {embedded}; }};")
        add("PBXTargetDependency", f"\t\t{dep} = {{isa = PBXTargetDependency; target = {target_ids[embedded]}; targetProxy = {proxy}; }};")
        phases.append(copy)
        deps.append(dep)

    if t.get("host"):
        dep, proxy = new(), new()
        add("PBXContainerItemProxy", f"\t\t{proxy} = {{isa = PBXContainerItemProxy; containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {target_ids[t['host']]}; remoteInfo = {t['host']}; }};")
        add("PBXTargetDependency", f"\t\t{dep} = {{isa = PBXTargetDependency; target = {target_ids[t['host']]}; targetProxy = {proxy}; }};")
        deps.append(dep)

    ts = {
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption": "NO",
        "PRODUCT_BUNDLE_IDENTIFIER": t["bundle"],
        "PRODUCT_NAME": t["product"],
        "ENABLE_PREVIEWS": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    if t["type"] == "app":
        ts["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    ts.update(t["settings"])

    groups = "".join(f"\t\t\t\t{folder_groups[f]},\n" for f in t["folders"])
    add("PBXNativeTarget", f"""\t\t{tid} /* {t['name']} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cfg_list};
\t\t\tbuildPhases = (\n{''.join(f'				{p},' + chr(10) for p in phases)}\t\t\t);
\t\t\tbuildRules = (\n\t\t\t);
\t\t\tdependencies = (\n{''.join(f'				{d},' + chr(10) for d in deps)}\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (\n{groups}\t\t\t);
\t\t\tname = {q(t['name'])};
\t\t\tpackageProductDependencies = (\n\t\t\t\t{dep_pkg},\n\t\t\t);
\t\t\tproductName = {q(t['product'])};
\t\t\tproductReference = {product};
\t\t\tproductType = {q(PRODUCT_TYPES[t['type']])};
\t\t}};""")
    add("PBXBuildFile", f"\t\t{bf_pkg} = {{isa = PBXBuildFile; productRef = {dep_pkg}; }};")
    add("PBXFileReference", f"\t\t{product} = {{isa = PBXFileReference; explicitFileType = {q(ftype)}; includeInIndex = 0; path = {q(t['product'] + ext)}; sourceTree = BUILT_PRODUCTS_DIR; }};")
    add("PBXFrameworksBuildPhase", f"\t\t{fw} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({bf_pkg},); runOnlyForDeploymentPostprocessing = 0; }};")
    add("PBXSourcesBuildPhase", f"\t\t{src} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
    add("PBXResourcesBuildPhase", f"\t\t{res} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};")
    add("XCSwiftPackageProductDependency", f"\t\t{dep_pkg} = {{isa = XCSwiftPackageProductDependency; productName = RekeepKit; }};")
    for cid, name in ((dbg, "Debug"), (rel, "Release")):
        add("XCBuildConfiguration", f"\t\t{cid} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{block(ts)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")
    add("XCConfigurationList", f"\t\t{cfg_list} = {{isa = XCConfigurationList; buildConfigurations = ({dbg}, {rel},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")

for cid, name, d in ((proj_debug, "Debug", debug_proj), (proj_release, "Release", release_proj)):
    add("XCBuildConfiguration", f"\t\t{cid} = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{block(d)}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};")
add("XCConfigurationList", f"\t\t{proj_cfg_list} = {{isa = XCConfigurationList; buildConfigurations = ({proj_debug}, {proj_release},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};")
add("XCLocalSwiftPackageReference", f"\t\t{pkg_ref} = {{isa = XCLocalSwiftPackageReference; relativePath = RekeepKit; }};")
children = "".join(f"\t\t\t\t{g},\n" for g in folder_groups.values())
add("PBXGroup", f"\t\t{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{children}\t\t\t\t{products_group},\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
prods = "".join(f"\t\t\t\t{p},\n" for p in product_refs.values())
add("PBXGroup", f"\t\t{products_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{prods}\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};")
tgts = "".join(f"\t\t\t\t{t},\n" for t in target_ids.values())
attrs = "".join(f"\t\t\t\t\t{t} = {{ CreatedOnToolsVersion = 27.0; }};\n" for t in target_ids.values())
add("PBXProject", f"""\t\t{project_id} = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2700;
\t\t\t\tLastUpgradeCheck = 2700;
\t\t\t\tTargetAttributes = {{\n{attrs}\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {proj_cfg_list};
\t\t\tcompatibilityVersion = "Xcode 15.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);
\t\t\tmainGroup = {main_group};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpackageReferences = (\n\t\t\t\t{pkg_ref},\n\t\t\t);
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {products_group};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (\n{tgts}\t\t\t);
\t\t}};""")

out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 77;", "\tobjects = {", ""]
for kind in sorted(sections):
    out.append(f"/* Begin {kind} section */")
    out.extend(sections[kind])
    out.append(f"/* End {kind} section */\n")
out += ["\t};", f"\trootObject = {project_id};", "}", ""]

path = os.path.join(ROOT, "Rekeep.xcodeproj")
os.makedirs(path, exist_ok=True)
with open(os.path.join(path, "project.pbxproj"), "w") as f:
    f.write("\n".join(out))
def scheme(name, build_target, test_target=None, storekit=None):
    def ref(t):
        prod = next(x for x in TARGETS if x["name"] == t)
        ext = WRAPPERS[prod["type"]][1]
        return (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_ids[t]}" '
                f'BuildableName = "{prod["product"]}{ext}" BlueprintName = "{t}" ReferencedContainer = "container:Rekeep.xcodeproj"></BuildableReference>')
    tests = (f'<Testables><TestableReference skipped = "NO">{ref(test_target)}</TestableReference></Testables>' if test_target else "<Testables></Testables>")
    sk = f'<StoreKitConfigurationFileReference identifier = "../../{storekit}"></StoreKitConfigurationFileReference>' if storekit else ""
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
<BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
<BuildActionEntries><BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">{ref(build_target)}</BuildActionEntry></BuildActionEntries>
</BuildAction>
<TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">{tests}</TestAction>
<LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
<BuildableProductRunnable runnableDebuggingMode = "0">{ref(build_target)}</BuildableProductRunnable>{sk}
</LaunchAction>
<ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"></ProfileAction>
<AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
<ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""
    d = os.path.join(path, "xcshareddata", "xcschemes")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, name + ".xcscheme"), "w") as f:
        f.write(xml)

scheme("Rekeep", "Rekeep")
scheme("RekeepMobile", "RekeepMobile")
print("wrote", path)
