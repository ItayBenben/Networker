#!/usr/bin/env python3
"""Regenerates Networker.xcodeproj/project.pbxproj from the files on disk.

Run it after adding, moving or removing source files:

    python3 Scripts/generate_xcodeproj.py

Identifiers are derived from file paths, so re-running produces a stable project.
"""
import hashlib
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT_NAME = "Networker"
APP_DIR = "Networker"
EXT_DIR = "NetworkerTunnel"
SHARED_DIR = "Shared"
CONFIG_DIR = "Config"
XCCONFIG = "Config/Networker.xcconfig"
DEPLOYMENT_TARGET = "17.0"

FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".entitlements": "text.plist.entitlements",
    ".plist": "text.plist.xml",
    ".xcassets": "folder.assetcatalog",
    ".xcconfig": "text.xcconfig",
    ".md": "net.daringfireball.markdown",
}


def oid(name):
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()


def q(value):
    if re.fullmatch(r"[A-Za-z0-9_./]+", value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Emitter:
    def __init__(self):
        self.sections = {}

    def add(self, isa, ident, comment, body):
        self.sections.setdefault(isa, []).append((ident, comment, body))

    def render(self, root_object):
        out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
               "\tobjectVersion = 56;", "\tobjects = {", ""]
        for isa in sorted(self.sections):
            out.append(f"/* Begin {isa} section */")
            for ident, comment, body in sorted(self.sections[isa], key=lambda item: item[0]):
                label = f"{ident} /* {comment} */" if comment else ident
                out.append(f"\t\t{label} = {{")
                out.extend(body)
                out.append("\t\t};")
            out.append(f"/* End {isa} section */")
            out.append("")
        out.append("\t};")
        out.append(f"\trootObject = {root_object} /* Project object */;")
        out.append("}")
        return "\n".join(out) + "\n"


def settings_lines(settings, indent):
    lines = []
    pad = "\t" * indent
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            lines.append(f"{pad}{key} = (")
            for item in value:
                lines.append(f"{pad}\t{q(item)},")
            lines.append(f"{pad});")
        else:
            lines.append(f"{pad}{key} = {q(str(value))};")
    return lines


def collect_tree(emitter, directory, rel_path, group_name=None):
    """Creates PBXGroup/PBXFileReference objects for a folder. Returns (group id, [file infos])."""
    files = []
    children = []
    entries = sorted(directory.iterdir(), key=lambda p: (p.is_file(), p.name.lower()))
    for entry in entries:
        if entry.name.startswith("."):
            continue
        entry_rel = f"{rel_path}/{entry.name}" if rel_path else entry.name
        if entry.is_dir() and entry.suffix != ".xcassets":
            child_group, child_files = collect_tree(emitter, entry, entry_rel)
            children.append((child_group, entry.name))
            files.extend(child_files)
            continue
        file_type = FILE_TYPES.get(entry.suffix)
        if file_type is None:
            continue
        ref = oid("fileref:" + entry_rel)
        emitter.add("PBXFileReference", ref, entry.name, [
            f"\t\t\tisa = PBXFileReference;",
            f"\t\t\tlastKnownFileType = {q(file_type)};",
            f"\t\t\tpath = {q(entry.name)};",
            f"\t\t\tsourceTree = {q('<group>')};",
        ])
        children.append((ref, entry.name))
        files.append({"ref": ref, "rel": entry_rel, "name": entry.name, "suffix": entry.suffix})
    group = oid("group:" + rel_path)
    name = group_name or directory.name
    body = ["\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
    body += [f"\t\t\t\t{ident} /* {label} */," for ident, label in children]
    body += ["\t\t\t);", f"\t\t\tpath = {q(directory.name)};", f"\t\t\tsourceTree = {q('<group>')};"]
    emitter.add("PBXGroup", group, name, body)
    return group, files


def main():
    e = Emitter()
    project_id = oid("project")
    main_group = oid("group:main")
    products_group = oid("group:products")

    app_group, app_files = collect_tree(e, ROOT / APP_DIR, APP_DIR)
    ext_group, ext_files = collect_tree(e, ROOT / EXT_DIR, EXT_DIR)
    shared_group, shared_files = collect_tree(e, ROOT / SHARED_DIR, SHARED_DIR)
    config_group, config_files = collect_tree(e, ROOT / CONFIG_DIR, CONFIG_DIR)
    xcconfig_ref = next(f["ref"] for f in config_files if f["rel"] == XCCONFIG)

    app_product = oid("product:app")
    ext_product = oid("product:ext")
    e.add("PBXFileReference", app_product, f"{PROJECT_NAME}.app", [
        "\t\t\tisa = PBXFileReference;",
        "\t\t\texplicitFileType = wrapper.application;",
        "\t\t\tincludeInIndex = 0;",
        f"\t\t\tpath = {q(PROJECT_NAME + '.app')};",
        "\t\t\tsourceTree = BUILT_PRODUCTS_DIR;",
    ])
    e.add("PBXFileReference", ext_product, f"{EXT_DIR}.appex", [
        "\t\t\tisa = PBXFileReference;",
        f"\t\t\texplicitFileType = {q('wrapper.app-extension')};",
        "\t\t\tincludeInIndex = 0;",
        f"\t\t\tpath = {q(EXT_DIR + '.appex')};",
        "\t\t\tsourceTree = BUILT_PRODUCTS_DIR;",
    ])
    e.add("PBXGroup", products_group, "Products", [
        "\t\t\tisa = PBXGroup;", "\t\t\tchildren = (",
        f"\t\t\t\t{app_product} /* {PROJECT_NAME}.app */,",
        f"\t\t\t\t{ext_product} /* {EXT_DIR}.appex */,",
        "\t\t\t);", "\t\t\tname = Products;", f"\t\t\tsourceTree = {q('<group>')};",
    ])
    e.add("PBXGroup", main_group, "", [
        "\t\t\tisa = PBXGroup;", "\t\t\tchildren = (",
        f"\t\t\t\t{app_group} /* {APP_DIR} */,",
        f"\t\t\t\t{ext_group} /* {EXT_DIR} */,",
        f"\t\t\t\t{shared_group} /* {SHARED_DIR} */,",
        f"\t\t\t\t{config_group} /* {CONFIG_DIR} */,",
        f"\t\t\t\t{products_group} /* Products */,",
        "\t\t\t);", f"\t\t\tsourceTree = {q('<group>')};",
    ])

    def build_file(target, info, phase_label):
        ident = oid(f"buildfile:{target}:{info['rel']}")
        e.add("PBXBuildFile", ident, f"{info['name']} in {phase_label}", [
            "\t\t\tisa = PBXBuildFile;",
            f"\t\t\tfileRef = {info['ref']} /* {info['name']} */;",
        ])
        return ident, info["name"]

    def phase(isa, ident, name, entries, extra=None):
        body = [f"\t\t\tisa = {isa};", "\t\t\tbuildActionMask = 2147483647;"]
        if extra:
            body += extra
        body += ["\t\t\tfiles = ("]
        body += [f"\t\t\t\t{bf} /* {label} in {name} */," for bf, label in entries]
        body += ["\t\t\t);"]
        if isa == "PBXCopyFilesBuildPhase":
            body += [f"\t\t\tname = {q(name)};"]
        body += ["\t\t\trunOnlyForDeploymentPostprocessing = 0;"]
        e.add(isa, ident, name, body)

    app_sources = [build_file("app", f, "Sources") for f in app_files + shared_files if f["suffix"] == ".swift"]
    app_resources = [build_file("app", f, "Resources") for f in app_files if f["suffix"] == ".xcassets"]
    ext_sources = [build_file("ext", f, "Sources") for f in ext_files + shared_files if f["suffix"] == ".swift"]

    embed_file = oid("buildfile:app:embed-ext")
    e.add("PBXBuildFile", embed_file, f"{EXT_DIR}.appex in Embed Foundation Extensions", [
        "\t\t\tisa = PBXBuildFile;",
        f"\t\t\tfileRef = {ext_product} /* {EXT_DIR}.appex */;",
        "\t\t\tsettings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); };",
    ])

    app_sources_phase = oid("phase:app:sources")
    app_frameworks_phase = oid("phase:app:frameworks")
    app_resources_phase = oid("phase:app:resources")
    app_embed_phase = oid("phase:app:embed")
    ext_sources_phase = oid("phase:ext:sources")
    ext_frameworks_phase = oid("phase:ext:frameworks")
    ext_resources_phase = oid("phase:ext:resources")

    phase("PBXSourcesBuildPhase", app_sources_phase, "Sources", app_sources)
    phase("PBXFrameworksBuildPhase", app_frameworks_phase, "Frameworks", [])
    phase("PBXResourcesBuildPhase", app_resources_phase, "Resources", app_resources)
    phase("PBXCopyFilesBuildPhase", app_embed_phase, "Embed Foundation Extensions",
          [(embed_file, f"{EXT_DIR}.appex")],
          extra=[f"\t\t\tdstPath = {q('')};", "\t\t\tdstSubfolderSpec = 13;"])
    phase("PBXSourcesBuildPhase", ext_sources_phase, "Sources", ext_sources)
    phase("PBXFrameworksBuildPhase", ext_frameworks_phase, "Frameworks", [])
    phase("PBXResourcesBuildPhase", ext_resources_phase, "Resources", [])

    app_target = oid("target:app")
    ext_target = oid("target:ext")
    proxy = oid("proxy:app->ext")
    dependency = oid("dependency:app->ext")
    e.add("PBXContainerItemProxy", proxy, "PBXContainerItemProxy", [
        "\t\t\tisa = PBXContainerItemProxy;",
        f"\t\t\tcontainerPortal = {project_id} /* Project object */;",
        "\t\t\tproxyType = 1;",
        f"\t\t\tremoteGlobalIDString = {ext_target};",
        f"\t\t\tremoteInfo = {EXT_DIR};",
    ])
    e.add("PBXTargetDependency", dependency, "PBXTargetDependency", [
        "\t\t\tisa = PBXTargetDependency;",
        f"\t\t\ttarget = {ext_target} /* {EXT_DIR} */;",
        f"\t\t\ttargetProxy = {proxy} /* PBXContainerItemProxy */;",
    ])

    common_project = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++20",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
        "CLANG_WARN_STRICT_PROTOTYPES": "YES",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
        "MTL_FAST_MATH": "YES",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    project_debug = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_DYNAMIC_NO_PIC": "NO",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(common_project, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    })
    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": f"{APP_DIR}/{PROJECT_NAME}.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "Networker",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_BASE)",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }
    ext_settings = {
        "CODE_SIGN_ENTITLEMENTS": f"{EXT_DIR}/{EXT_DIR}.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_FILE": f"{EXT_DIR}/Info.plist",
        "INFOPLIST_KEY_CFBundleDisplayName": "Networker Tunnel",
        "INFOPLIST_KEY_NSHumanReadableCopyright": "",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "$(BUNDLE_ID_BASE).tunnel",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SKIP_INSTALL": "YES",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
    }

    def configuration(ident, name, settings, base=None):
        body = ["\t\t\tisa = XCBuildConfiguration;"]
        if base:
            body.append(f"\t\t\tbaseConfigurationReference = {base} /* Networker.xcconfig */;")
        body.append("\t\t\tbuildSettings = {")
        body += settings_lines(settings, 4)
        body.append("\t\t\t};")
        body.append(f"\t\t\tname = {name};")
        e.add("XCBuildConfiguration", ident, name, body)

    def configuration_list(ident, comment, debug, release):
        e.add("XCConfigurationList", ident, comment, [
            "\t\t\tisa = XCConfigurationList;",
            "\t\t\tbuildConfigurations = (",
            f"\t\t\t\t{debug} /* Debug */,",
            f"\t\t\t\t{release} /* Release */,",
            "\t\t\t);",
            "\t\t\tdefaultConfigurationIsVisible = 0;",
            "\t\t\tdefaultConfigurationName = Release;",
        ])

    ids = {name: oid("config:" + name) for name in
           ("project:Debug", "project:Release", "app:Debug", "app:Release", "ext:Debug", "ext:Release")}
    configuration(ids["project:Debug"], "Debug", project_debug, base=xcconfig_ref)
    configuration(ids["project:Release"], "Release", project_release, base=xcconfig_ref)
    configuration(ids["app:Debug"], "Debug", app_settings)
    configuration(ids["app:Release"], "Release", app_settings)
    configuration(ids["ext:Debug"], "Debug", ext_settings)
    configuration(ids["ext:Release"], "Release", ext_settings)

    project_list = oid("configlist:project")
    app_list = oid("configlist:app")
    ext_list = oid("configlist:ext")
    configuration_list(project_list, f'Build configuration list for PBXProject "{PROJECT_NAME}"',
                       ids["project:Debug"], ids["project:Release"])
    configuration_list(app_list, f'Build configuration list for PBXNativeTarget "{PROJECT_NAME}"',
                       ids["app:Debug"], ids["app:Release"])
    configuration_list(ext_list, f'Build configuration list for PBXNativeTarget "{EXT_DIR}"',
                       ids["ext:Debug"], ids["ext:Release"])

    e.add("PBXNativeTarget", app_target, PROJECT_NAME, [
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {app_list} /* Build configuration list for PBXNativeTarget \"{PROJECT_NAME}\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{app_sources_phase} /* Sources */,",
        f"\t\t\t\t{app_frameworks_phase} /* Frameworks */,",
        f"\t\t\t\t{app_resources_phase} /* Resources */,",
        f"\t\t\t\t{app_embed_phase} /* Embed Foundation Extensions */,",
        "\t\t\t);",
        "\t\t\tbuildRules = (",
        "\t\t\t);",
        "\t\t\tdependencies = (",
        f"\t\t\t\t{dependency} /* PBXTargetDependency */,",
        "\t\t\t);",
        f"\t\t\tname = {PROJECT_NAME};",
        f"\t\t\tproductName = {PROJECT_NAME};",
        f"\t\t\tproductReference = {app_product} /* {PROJECT_NAME}.app */;",
        f"\t\t\tproductType = {q('com.apple.product-type.application')};",
    ])
    e.add("PBXNativeTarget", ext_target, EXT_DIR, [
        "\t\t\tisa = PBXNativeTarget;",
        f"\t\t\tbuildConfigurationList = {ext_list} /* Build configuration list for PBXNativeTarget \"{EXT_DIR}\" */;",
        "\t\t\tbuildPhases = (",
        f"\t\t\t\t{ext_sources_phase} /* Sources */,",
        f"\t\t\t\t{ext_frameworks_phase} /* Frameworks */,",
        f"\t\t\t\t{ext_resources_phase} /* Resources */,",
        "\t\t\t);",
        "\t\t\tbuildRules = (",
        "\t\t\t);",
        "\t\t\tdependencies = (",
        "\t\t\t);",
        f"\t\t\tname = {EXT_DIR};",
        f"\t\t\tproductName = {EXT_DIR};",
        f"\t\t\tproductReference = {ext_product} /* {EXT_DIR}.appex */;",
        f"\t\t\tproductType = {q('com.apple.product-type.app-extension')};",
    ])

    e.add("PBXProject", project_id, "Project object", [
        "\t\t\tisa = PBXProject;",
        "\t\t\tattributes = {",
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
        "\t\t\t\tLastSwiftUpdateCheck = 1500;",
        "\t\t\t\tLastUpgradeCheck = 1500;",
        "\t\t\t\tTargetAttributes = {",
        f"\t\t\t\t\t{app_target} = {{",
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;",
        "\t\t\t\t\t};",
        f"\t\t\t\t\t{ext_target} = {{",
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;",
        "\t\t\t\t\t};",
        "\t\t\t\t};",
        "\t\t\t};",
        f"\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;",
        f"\t\t\tcompatibilityVersion = {q('Xcode 14.0')};",
        "\t\t\tdevelopmentRegion = en;",
        "\t\t\thasScannedForEncodings = 0;",
        "\t\t\tknownRegions = (",
        "\t\t\t\ten,",
        "\t\t\t\tBase,",
        "\t\t\t);",
        f"\t\t\tmainGroup = {main_group};",
        f"\t\t\tproductRefGroup = {products_group} /* Products */;",
        f"\t\t\tprojectDirPath = {q('')};",
        f"\t\t\tprojectRoot = {q('')};",
        "\t\t\ttargets = (",
        f"\t\t\t\t{app_target} /* {PROJECT_NAME} */,",
        f"\t\t\t\t{ext_target} /* {EXT_DIR} */,",
        "\t\t\t);",
    ])

    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text(e.render(project_id))

    scheme_dir = project_dir / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = (f'            <BuildableReference\n'
                 f'               BuildableIdentifier = "primary"\n'
                 f'               BlueprintIdentifier = "{app_target}"\n'
                 f'               BuildableName = "{PROJECT_NAME}.app"\n'
                 f'               BlueprintName = "{PROJECT_NAME}"\n'
                 f'               ReferencedContainer = "container:{PROJECT_NAME}.xcodeproj">\n'
                 f'            </BuildableReference>\n')
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
{reference}         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{reference}      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
{reference}      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    (scheme_dir / f"{PROJECT_NAME}.xcscheme").write_text(scheme)
    print(f"wrote {project_dir / 'project.pbxproj'}: "
          f"{len(app_sources)} app sources, {len(ext_sources)} extension sources")


if __name__ == "__main__":
    main()
