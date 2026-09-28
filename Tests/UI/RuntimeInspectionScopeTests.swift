#if canImport(UIKit)
import XCTest
import UIKit
import ObjectiveC.runtime
import BODragScroll
@testable import AppAgent

@MainActor
final class RuntimeInspectionScopeTests: XCTestCase {
    private let host = HostInspectionContext()
    private let sdk = HostInspectionContext(scope: .appagent)
    private let all = HostInspectionContext(scope: .all)

    private func mixedTree() -> (UIView, UIView, UILabel, UILabel) {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        let sdkRoot = UIView(frame: root.bounds)
        HostInspectionUIKit.markAppAgentOwned(sdkRoot)
        let secret = UILabel()
        secret.text = "SDK-PRIVATE-TEXT"
        secret.accessibilityIdentifier = "SDK-PRIVATE-ID"
        sdkRoot.addSubview(secret)
        let visible = UILabel(frame: root.bounds)
        visible.text = "HOST-TEXT"
        root.addSubview(sdkRoot) // Excluded index 0 must NOT renumber the host label at 1.
        root.addSubview(visible)
        return (root, sdkRoot, secret, visible)
    }

    func testOwnershipPropagatesToPlainUIKitWithoutClaimingSharedDependencies() {
        let (root, sdkRoot, secret, visible) = mixedTree()
        XCTAssertFalse(HostInspectionUIKit.isAppAgentOwned(root))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(sdkRoot))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(secret))
        XCTAssertFalse(HostInspectionUIKit.isAppAgentOwned(visible))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentClass(AppAgentViewController.self))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentClass(ScopeSDKController.self))
        XCTAssertFalse(HostInspectionUIKit.isAppAgentClass(BODragScrollView.self))
        XCTAssertFalse(HostInspectionUIKit.isAppAgentClass(UIView.self))
        let sharedView = BODragScrollView()
        XCTAssertFalse(HostInspectionUIKit.isAppAgentOwned(sharedView))
        sdkRoot.addSubview(sharedView)
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(sharedView))
    }

    func testSDKClassIdentitiesWorkWithoutModuleOrImageFallback() {
        // Test the identity-only branch: otherwise package-built tests would hide a broken
        // source integration behind the AppAgent module prefix. Do not instantiate UIWindow.
        let sdkTypes: [AnyClass] = [
            AIAgent.self, AIAgentCentral.self, AISession.self, AISessionManager.self,
            LLMExecutor.self, RunGovernor.self, SessionUIState.self, DecisionResponderCentral.self,
            InMemorySessionStorage.self, FileSessionStorage.self,
            ToolCentral.self, ModelProviderCentral.self, AnthropicProvider.self,
            MemoryStore.self, HotMemory.self, InMemoryMemoryStorage.self, FileMemoryStorage.self,
            SkillsManager.self, TodoTool.self, AppAgentDebugLog.self, AppAgentRunLog.self,
            UnfairLock.self, ReadersWriterLock.self, ReadySignal.self, ConcurrencyLimiter.self,
            HostInspectionAuthorization.self, DecisionWaiter.self, DefaultRuntimeInspectProvider.self,
            AppAgentWindow.self, AppAgentRegionDebugWindow.self,
            AppAgentViewController.self, ScopeSDKController.self,
            AppAgentDebugViewController.self, AppAgentRegionDebugViewController.self,
            AppAgentSettingsViewController.self, AppAgentTextField.self,
            AppAgentChatPanelView.self, ChatMessageCell.self,
            AppAgentVoiceInputOverlayView.self
        ]
        for cls in sdkTypes {
            XCTAssertTrue(HostInspectionUIKit.isKnownAppAgentClass(cls), String(reflecting: cls))
        }
        #if canImport(JavaScriptCore)
        XCTAssertTrue(HostInspectionUIKit.isKnownAppAgentClass(DefaultHotfixProvider.self))
        #endif
        // These fixtures share the SDK subclass's test module/image, just like source-integrated
        // host and SDK types. A suggestive class name is not sufficient to claim ownership.
        let hostTypes: [AnyClass] = [
            ScopeLinkView.self, AppAgentHostNamedView.self, ScopeRecordingRuntimeProvider.self,
            ScopeHostBox<AISession>.self, ScopeHostBox<UIView>.self,
            NSObject.self, UIView.self, UIWindow.self, UIViewController.self, BODragScrollView.self
        ]
        for cls in hostTypes {
            XCTAssertFalse(HostInspectionUIKit.isKnownAppAgentClass(cls), String(reflecting: cls))
            XCTAssertFalse(HostInspectionUIKit.isAppAgentClass(cls), String(reflecting: cls))
        }
    }

    func testGenericAndPrivateMetadataUseIdentityWithoutInstancesOrFallback() {
        // Multiple specializations, including the registry's real private nested class.
        // NSStringFromClass is deliberately avoided: private/generic metadata need not have
        // a Foundation-compatible class name. Neither a name nor an instance is needed here.
        let types: [AnyClass] = [
            Locked<Int>.self, Locked<String>.self,
            WeakLocked<UIView>.self, WeakLocked<AISession>.self,
            TrackedLocked<Int>.self, TrackedLocked<String>.self,
            HostInspectionHandleRegistry<NSObject>.self, HostInspectionHandleRegistry<ScopeLinkView>.self,
            HostInspectionHandleRegistry<NSObject>.entryClass,
            HostInspectionHandleRegistry<ScopeLinkView>.entryClass
        ]
        XCTAssertNotEqual(ObjectIdentifier(HostInspectionHandleRegistry<NSObject>.entryClass),
                          ObjectIdentifier(HostInspectionHandleRegistry<ScopeLinkView>.entryClass))
        for cls in types {
            XCTAssertTrue(HostInspectionUIKit.isKnownAppAgentClass(cls), String(reflecting: cls))
        }
    }

    func testActualPrivateUIClassMetadataDoesNotDependOnSDKAncestor() throws {
        let panel = AppAgentChatPanelView(frame: .zero)
        let background = try XCTUnwrap(panel.contentAreaView.subviews.first {
            String(describing: type(of: $0)) == "AppAgentChatPanelBackgroundView"
        })
        background.removeFromSuperview()
        XCTAssertNil(background.superview)
        // Only the metatype enters this check; ancestor ownership cannot make it pass.
        XCTAssertTrue(HostInspectionUIKit.isKnownAppAgentClass(type(of: background)))
        XCTAssertFalse(HostInspectionUIKit.isKnownAppAgentClass(UIView.self))
    }

    func testKnownSDKComponentOwnsPlainDescendantsWithoutExplicitMark() {
        let root = AppAgentHostNamedView()
        let field = AppAgentTextField(frame: .zero)
        let plainChild = UILabel()
        field.addSubview(plainChild)
        root.addSubview(field)
        XCTAssertFalse(HostInspectionUIKit.isAppAgentOwned(root))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(field))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(plainChild))
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "0", root: root))
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "0", root: root, context: sdk) === field)
        XCTAssertEqual(DefaultRuntimeInspectProvider.stats(of: root).views, 1)
    }

    func testRuntimeClassFilterUsesKnownIdentitiesWithoutClaimingNamedHostClass() async {
        let provider = DefaultRuntimeInspectProvider()
        for cls: AnyClass in [AppAgentWindow.self, AppAgentRegionDebugWindow.self, AppAgentTextField.self,
                             AIAgent.self, AISession.self, MemoryStore.self] {
            let name = NSStringFromClass(cls)
            XCTAssertTrue(HostInspectionUIKit.isKnownAppAgentClass(cls))
            XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(name, context: host))
            XCTAssertNotNil(DefaultRuntimeInspectProvider.resolveClass(name, context: sdk))
            let shortName = String(describing: cls)
            XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(shortName, context: host))
            XCTAssertNotNil(DefaultRuntimeInspectProvider.resolveClass(shortName, context: all))
            let hostClasses = await provider.classList(matching: name, context: host)
            let sdkClasses = await provider.classList(matching: name, context: sdk)
            XCTAssertFalse(hostClasses.contains(name))
            XCTAssertTrue(sdkClasses.contains(name))
            let methods = await provider.methodList(ofClass: name, context: host)
            let properties = await provider.propertyList(ofClass: shortName, context: host)
            XCTAssertTrue(methods.first?.hasPrefix("(class not found") == true)
            XCTAssertTrue(properties.first?.hasPrefix("(class not found") == true)
        }
        let hostName = NSStringFromClass(AppAgentHostNamedView.self)
        XCTAssertNotNil(DefaultRuntimeInspectProvider.resolveClass(hostName, context: host))
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(hostName, context: sdk))
        let hostClasses = await provider.classList(matching: hostName, context: host)
        XCTAssertTrue(hostClasses.contains(hostName))
    }

    func testClassCandidateFilterChecksOnlyMatchingIdentities() throws {
        // A large nonmatching population must not cause protocol casts/superclass walks.
        let unrelated = Array<AnyClass>(repeating: UIView.self, count: 2_048)
        let sdkClass: AnyClass = AppAgentTextField.self
        let hostClass: AnyClass = AppAgentHostNamedView.self
        let classes = unrelated + [sdkClass, hostClass, BODragScrollView.self]
        for context in [host, sdk, all] {
            var checked: [ObjectIdentifier] = []
            let candidates = try XCTUnwrap(DefaultRuntimeInspectProvider.scopedClassCandidates(
                in: classes,
                matching: { $0.range(of: "appagent", options: .caseInsensitive) != nil },
                context: context,
                scopeCheck: { cls, receivedContext in
                    XCTAssertEqual(receivedContext, context)
                    checked.append(ObjectIdentifier(cls))
                    return DefaultRuntimeInspectProvider.classIncluded(cls, context: receivedContext)
                }
            ))
            XCTAssertEqual(checked, [ObjectIdentifier(sdkClass), ObjectIdentifier(hostClass)])
            let expected: [AnyClass]
            switch context.scope {
            case .host: expected = [hostClass]
            case .appagent: expected = [sdkClass]
            case .all: expected = [sdkClass, hostClass]
            }
            XCTAssertEqual(candidates.map { ObjectIdentifier($0.cls) }, expected.map { ObjectIdentifier($0) })
            XCTAssertEqual(candidates.map(\.name), expected.map { String(cString: class_getName($0)) })
        }
    }

    func testShortNameCandidateFilterChecksOnlyExactSuffixAndSkipsMisses() throws {
        let classes: [AnyClass] = [UIView.self, BODragScrollView.self, AppAgentTextField.self, AppAgentHostNamedView.self]
        for (suffix, expectedChecks) in [(".AppAgentTextField", 1), (".TextField", 0), (".MissingScopeType", 0)] {
            var checks = 0
            let candidates = try XCTUnwrap(DefaultRuntimeInspectProvider.scopedClassCandidates(
                in: classes, matching: { $0.hasSuffix(suffix) }, context: host,
                scopeCheck: { cls, context in
                    checks += 1
                    return DefaultRuntimeInspectProvider.classIncluded(cls, context: context)
                }
            ))
            XCTAssertEqual(checks, expectedChecks, suffix)
            XCTAssertTrue(candidates.isEmpty, "Matching an excluded SDK class must not bypass scope")
        }
    }

    func testClassListFiltersCaseInsensitivelyAndKeepsRuntimeNames() async {
        let provider = DefaultRuntimeInspectProvider()
        let hostName = String(cString: class_getName(AppAgentHostNamedView.self))
        let sdkName = String(cString: class_getName(AppAgentTextField.self))
        let hostMatches = await provider.classList(matching: "appagenthostnamedview", context: host)
        let sdkMatches = await provider.classList(matching: "appagenthostnamedview", context: sdk)
        let allMatches = await provider.classList(matching: "appagenttextfield", context: all)
        XCTAssertTrue(hostMatches.contains(hostName))
        XCTAssertFalse(sdkMatches.contains(hostName))
        XCTAssertTrue(allMatches.contains(sdkName))
        XCTAssertEqual(hostMatches, hostMatches.sorted())
        XCTAssertEqual(allMatches, allMatches.sorted())
        let missing = await provider.classList(matching: "MissingScopeType-\(UUID().uuidString)", context: host)
        XCTAssertTrue(missing.isEmpty)
    }

    func testPrivateAndGenericCandidatesUseRawNamesAndStillEnforceScope() throws {
        // These metatypes need not have names accepted by NSStringFromClass.
        let sdkClass: AnyClass = HostInspectionHandleRegistry<NSObject>.entryClass
        let hostClass: AnyClass = ScopeHostBox<AISession>.self
        for cls in [sdkClass, hostClass] {
            let name = String(cString: class_getName(cls))
            for context in [host, sdk, all] {
                var checks = 0
                let candidates = try XCTUnwrap(DefaultRuntimeInspectProvider.scopedClassCandidates(
                    in: [UIView.self, sdkClass, hostClass],
                    matching: { $0 == name }, context: context,
                    scopeCheck: { candidate, context in
                        checks += 1
                        return DefaultRuntimeInspectProvider.classIncluded(candidate, context: context)
                    }
                ))
                XCTAssertEqual(checks, 1)
                let included = context.scope.includes(appAgentOwned: ObjectIdentifier(cls) == ObjectIdentifier(sdkClass))
                XCTAssertEqual(candidates.map(\.name), included ? [name] : [])
                let resolved: AnyClass? = DefaultRuntimeInspectProvider.resolveClass(name, context: context)
                XCTAssertEqual(resolved.map { ObjectIdentifier($0) }, included ? ObjectIdentifier(cls) : nil)
            }
        }
    }

    func testRuntimeShortNameAmbiguityFailsClosedAndDoesNotCacheMisses() throws {
        let shortName = "ScopeLookup\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(shortName, context: all))
        let first: AnyClass = try XCTUnwrap(objc_allocateClassPair(NSObject.self, "ScopeFirst." + shortName, 0))
        objc_registerClassPair(first)
        defer { objc_disposeClassPair(first) }
        XCTAssertEqual(DefaultRuntimeInspectProvider.resolveClass(shortName, context: all).map { ObjectIdentifier($0) },
                       ObjectIdentifier(first))
        let second: AnyClass = try XCTUnwrap(objc_allocateClassPair(NSObject.self, "ScopeSecond." + shortName, 0))
        objc_registerClassPair(second)
        defer { objc_disposeClassPair(second) }
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(shortName, context: all))
        XCTAssertEqual(DefaultRuntimeInspectProvider.resolveClass("ScopeFirst." + shortName, context: all)
            .map { ObjectIdentifier($0) }, ObjectIdentifier(first))
    }

    func testRuntimeBufferCandidatesUseCanonicalMetatypesBeforeOwnershipCheck() throws {
        let shortName = "ScopeCanonical\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let hostName = "ScopeHost." + shortName
        let sdkName = "ScopeSDK." + shortName
        let hostClass: AnyClass = try XCTUnwrap(objc_allocateClassPair(NSObject.self, hostName, 0))
        objc_registerClassPair(hostClass)
        defer { objc_disposeClassPair(hostClass) }
        let sdkClass: AnyClass = try XCTUnwrap(objc_allocateClassPair(AppAgentTextField.self, sdkName, 0))
        objc_registerClassPair(sdkClass)
        defer { objc_disposeClassPair(sdkClass) }
        let identities = [hostName: ObjectIdentifier(hostClass), sdkName: ObjectIdentifier(sdkClass)]

        // Deliberately use the raw ObjC output buffer, NOT a Swift array of canonical metatypes.
        // An ObjC-only class entry can have a different identity from objc_lookUpClass's result;
        // Swift-defined classes/subclasses need not. Only the returned canonical identity matters.
        let count = objc_getClassList(nil, 0)
        XCTAssertGreaterThan(count, 0)
        let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(count))
        defer { buffer.deallocate() }
        let realCount = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buffer), count)
        let classes = UnsafeBufferPointer(start: buffer, count: min(Int(realCount), Int(count)))
        for context in [host, sdk, all] {
            var checked: [String] = []
            let candidates = try XCTUnwrap(DefaultRuntimeInspectProvider.scopedClassCandidates(
                in: classes, matching: { $0.hasSuffix("." + shortName) }, context: context,
                scopeCheck: { cls, receivedContext in
                    let name = String(cString: class_getName(cls))
                    checked.append(name)
                    XCTAssertEqual(receivedContext, context)
                    XCTAssertEqual(ObjectIdentifier(cls), identities[name],
                                   "Scope checks must receive the canonical Swift metatype, not a raw ObjC entry")
                    return DefaultRuntimeInspectProvider.classIncluded(cls, context: receivedContext)
                }
            ))
            XCTAssertEqual(checked.count, 2, "Nonmatching runtime classes must never reach ownership checks")
            XCTAssertEqual(Set(checked), Set(identities.keys))
            let expectedNames: [String]
            switch context.scope {
            case .host: expectedNames = [hostName]
            case .appagent: expectedNames = [sdkName]
            case .all: expectedNames = [hostName, sdkName]
            }
            XCTAssertEqual(Set(candidates.map(\.name)), Set(expectedNames))
            for candidate in candidates {
                XCTAssertEqual(ObjectIdentifier(candidate.cls), identities[candidate.name])
            }
            // Scope still determines ownership; all sees the collision and must reject it.
            let resolved: AnyClass? = DefaultRuntimeInspectProvider.resolveClass(shortName, context: context)
            XCTAssertEqual(resolved.map { ObjectIdentifier($0) },
                           expectedNames.count == 1 ? identities[expectedNames[0]] : nil)
        }
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(sdkName, context: host))
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(hostName, context: sdk))
    }

    func testCancelledClassQueriesDoNotReturnResults() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            var checks = 0
            let candidates = DefaultRuntimeInspectProvider.scopedClassCandidates(
                in: [UIView.self], matching: { _ in true }, context: self.all,
                scopeCheck: { _, _ in checks += 1; return true }
            )
            XCTAssertNil(candidates)
            XCTAssertEqual(checks, 0)
            XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass("UIView", context: self.all))
            XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass("AppAgentTextField", context: self.all))
            let names = await DefaultRuntimeInspectProvider().classList(matching: nil, context: self.all)
            XCTAssertTrue(names.isEmpty)
        }
        await task.value
    }

    func testCancellationDuringClassScanDiscardsPartialCandidates() async {
        let task = Task { @MainActor in
            var checks = 0
            let candidates = DefaultRuntimeInspectProvider.scopedClassCandidates(
                in: [UIView.self, UILabel.self, UIButton.self],
                matching: { _ in true }, context: self.all,
                scopeCheck: { _, _ in
                    checks += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                }
            )
            XCTAssertNil(candidates, "A partial scan cannot establish short-name uniqueness")
            XCTAssertEqual(checks, 1)
        }
        await task.value
    }

    func testEmbeddedSDKControllerOwnsItsPlainRootWithoutOwningHostParent() {
        let parent = UIViewController()
        parent.view = UIView()
        let child = ScopeSDKController()
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        let label = UILabel()
        label.text = "embedded-secret"
        child.view.addSubview(label)
        XCTAssertFalse(HostInspectionUIKit.isAppAgentOwned(parent))
        XCTAssertFalse(HostInspectionUIKit.isAppAgentOwned(parent.view))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(child.view))
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(label))
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "0/0", root: parent.view))
        var full = ""
        DefaultRuntimeInspectProvider.describe(view: parent.view, indent: 0, into: &full)
        XCTAssertFalse(full.contains("embedded-secret"))
        XCTAssertEqual(DefaultRuntimeInspectProvider.stats(of: parent.view).views, 1)
    }

    func testMarkingUnloadedControllerDoesNotLoadItsView() {
        let controller = UIViewController()
        XCTAssertFalse(controller.isViewLoaded)
        HostInspectionUIKit.markAppAgentOwned(controller)
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(controller))
        XCTAssertFalse(controller.isViewLoaded)
        controller.view = UIView()
        XCTAssertTrue(HostInspectionUIKit.isAppAgentOwned(controller.view))
    }

    func testPathsAndEveryTreeRepresentationFilterBeforeCollecting() {
        let (root, sdkRoot, secret, visible) = mixedTree()
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "0", root: root))
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "0/0", root: root))
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "1", root: root) === visible)
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "0/0", root: root, context: sdk) === secret)
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "1", root: root, context: sdk))
        XCTAssertTrue(DefaultRuntimeInspectProvider.view(atPath: "0", root: root, context: all) === sdkRoot)
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "1//0", root: root))
        var tree = ""
        DefaultRuntimeInspectProvider.describeAddressable(
            view: root, path: "W7:root", depth: 0, maxDepth: 9, into: &tree
        )
        XCTAssertTrue(tree.contains("[W7:1]"))
        XCTAssertFalse(tree.contains("[W7:0]"))
        XCTAssertFalse(tree.contains("SDK-PRIVATE"))
        var anchors = ""
        DefaultRuntimeInspectProvider.emitAnchors(of: root, path: "W7:root", anchorDepth: 0, indent: 0, into: &anchors)
        XCTAssertTrue(anchors.contains("[W7:1]"))
        XCTAssertFalse(anchors.contains("SDK-PRIVATE"))
        XCTAssertEqual(DefaultRuntimeInspectProvider.stats(of: root).views, 2)
        XCTAssertEqual(DefaultRuntimeInspectProvider.stats(of: root).labels, 1)
        XCTAssertEqual(DefaultRuntimeInspectProvider.stats(of: sdkRoot).views, 0)
        XCTAssertFalse(DefaultRuntimeInspectProvider.isAnchor(secret))
        XCTAssertEqual(DefaultRuntimeInspectProvider.inlineLabel(of: secret), "")
        XCTAssertTrue(DefaultRuntimeInspectProvider.describeState(of: secret, path: "0/0").hasPrefix("Inspection denied:"))
        var sdkTree = ""
        DefaultRuntimeInspectProvider.describeAddressable(
            view: root, path: "root", depth: 0, maxDepth: 9, context: sdk, into: &sdkTree
        )
        XCTAssertTrue(sdkTree.contains("SDK-PRIVATE-TEXT"))
        XCTAssertFalse(sdkTree.contains("HOST-TEXT"))
        var allTree = ""
        DefaultRuntimeInspectProvider.describeAddressable(
            view: root, path: "root", depth: 0, maxDepth: 9, context: all, into: &allTree
        )
        XCTAssertTrue(allTree.contains("SDK-PRIVATE-TEXT"))
        XCTAssertTrue(allTree.contains("HOST-TEXT"))
    }

    func testControllerSkeletonCountsAndTitlesExcludeSDK() {
        let hostPage = UIViewController()
        hostPage.title = "HOST-PAGE"
        let sdkPage = UIViewController()
        sdkPage.title = "SDK-PRIVATE-PAGE"
        HostInspectionUIKit.markAppAgentOwned(sdkPage)
        let nav = UINavigationController()
        nav.view = UIView()
        nav.setViewControllers([hostPage, sdkPage], animated: false)
        var text = ""
        DefaultRuntimeInspectProvider.describeVCSkeleton(nav, indent: 0, into: &text)
        XCTAssertTrue(text.contains("页面栈 1 层"))
        XCTAssertTrue(text.contains("HOST-PAGE"))
        XCTAssertFalse(text.contains("SDK-PRIVATE-PAGE"))
        var full = ""
        DefaultRuntimeInspectProvider.describe(viewController: nav, indent: 0, into: &full)
        XCTAssertFalse(full.contains("SDK-PRIVATE-PAGE"))
    }

    func testClassPathsEnforceScopeIncludingSubclassAndShortName() async {
        let provider = DefaultRuntimeInspectProvider()
        let name = NSStringFromClass(ScopeSDKController.self)
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass(name))
        XCTAssertNotNil(DefaultRuntimeInspectProvider.resolveClass(name, context: sdk))
        XCTAssertNotNil(DefaultRuntimeInspectProvider.resolveClass("AppAgentViewController", context: all))
        XCTAssertNil(DefaultRuntimeInspectProvider.resolveClass("AppAgentViewController"))
        let hostClasses = await provider.classList(matching: "ScopeSDKController", context: host)
        let sdkClasses = await provider.classList(matching: "ScopeSDKController", context: sdk)
        XCTAssertTrue(hostClasses.isEmpty)
        XCTAssertTrue(sdkClasses.contains(name))
        let methods = await provider.methodList(ofClass: name, context: host)
        let properties = await provider.propertyList(ofClass: name, context: host)
        XCTAssertTrue(methods.first?.hasPrefix("(class not found") == true)
        XCTAssertTrue(properties.first?.hasPrefix("(class not found") == true)
        XCTAssertNil(DefaultRuntimeInspectProvider.kvcTarget(className: "UIApplication", context: host))
    }

    func testKeyPathTraversalRejectsSDKBeforeReadingOrWritingNextKey() {
        let root = ScopeLinkView()
        let secret = ScopeProbeView()
        HostInspectionUIKit.markAppAgentOwned(secret)
        root.link = secret
        XCTAssertTrue(DefaultRuntimeInspectProvider.readProperty(from: root, keyPath: "link.secret").hasPrefix("Inspection denied:"))
        XCTAssertEqual(secret.reads, 0)
        let write = DefaultRuntimeInspectProvider.writeProperty(on: root, keyPath: "link.tag", value: "9")
        XCTAssertTrue(write.hasPrefix("Inspection denied:"))
        XCTAssertEqual(secret.tag, 0)
        XCTAssertTrue(DefaultRuntimeInspectProvider.readProperty(from: root, keyPath: "link").hasPrefix("Inspection denied:"))
        let allowed = UILabel()
        allowed.text = "allowed"
        root.link = allowed
        XCTAssertEqual(DefaultRuntimeInspectProvider.readProperty(from: root, keyPath: "link.text"), "allowed")
        XCTAssertTrue(DefaultRuntimeInspectProvider.writeProperty(on: root, keyPath: "link.text", value: "changed").hasPrefix("OK."))
        XCTAssertEqual(allowed.text, "changed")
        XCTAssertTrue(DefaultRuntimeInspectProvider.applyValue(to: secret, key: "alpha", value: "0").hasPrefix("Inspection denied:"))
        XCTAssertEqual(secret.alpha, 1)
    }

    func testCollectionsAndUnknownDescriptionsNeverStringifyNestedSDK() throws {
        let root = ScopeLinkView()
        let secret = ScopeProbeView()
        HostInspectionUIKit.markAppAgentOwned(secret)
        root.payload = ["nested": [secret]]
        XCTAssertTrue(DefaultRuntimeInspectProvider.readProperty(from: root, keyPath: "payload").hasPrefix("Inspection denied:"))
        XCTAssertThrowsError(try DefaultRuntimeInspectProvider.inspectedDescription(of: root.payload))
        XCTAssertTrue(DefaultRuntimeInspectProvider.readProperty(from: root, keyPath: "subviews.@count").hasPrefix("Inspection denied:"))
        XCTAssertTrue(DefaultRuntimeInspectProvider.readProperty(from: root, keyPath: "description").hasPrefix("Inspection denied:"))
        XCTAssertEqual(secret.descriptions, 0)
        XCTAssertEqual(try DefaultRuntimeInspectProvider.inspectedDescription(of: NSNumber(value: 3), context: sdk), "3")
    }

    func testSelectorsRejectUnknownChainsClassBypassesAndExcludedTargets() {
        let (root, _, secret, visible) = mixedTree()
        XCTAssertNotNil(DefaultRuntimeInspectProvider.selectorRejection(NSSelectorFromString("description"), on: visible, argCount: 0))
        XCTAssertNotNil(DefaultRuntimeInspectProvider.selectorRejection(#selector(UIView.setNeedsLayout), on: secret, argCount: 0))
        XCTAssertNotNil(DefaultRuntimeInspectProvider.selectorRejection(#selector(UIView.removeFromSuperview), on: root, argCount: 0))
        XCTAssertNil(DefaultRuntimeInspectProvider.selectorRejection(#selector(UIView.setNeedsLayout), on: visible, argCount: 0))
        XCTAssertNil(DefaultRuntimeInspectProvider.selectorRejection(NSSelectorFromString("description"), on: secret, argCount: 0, context: all))
    }

    func testSceneSelectionFailsClosedAndHonorsBinding() throws {
        let scenes: [(id: String, active: Bool)] = [("B", true), ("A", true), ("inactive", false)]
        XCTAssertThrowsError(try HostInspectionUIKit.selectSceneIdentifier(candidates: scenes, requested: nil))
        XCTAssertEqual(try HostInspectionUIKit.selectSceneIdentifier(candidates: scenes, requested: "A"), "A")
        XCTAssertThrowsError(try HostInspectionUIKit.selectSceneIdentifier(candidates: scenes, requested: "gone"))
        XCTAssertThrowsError(try HostInspectionUIKit.selectSceneIdentifier(candidates: scenes, requested: "inactive"))
        XCTAssertEqual(try HostInspectionUIKit.selectSceneIdentifier(candidates: [("B", false), ("A", true)], requested: nil), "A")
        XCTAssertThrowsError(try HostInspectionUIKit.selectSceneIdentifier(candidates: [], requested: nil))
        let detached = UIView()
        XCTAssertNil(DefaultRuntimeInspectProvider.view(atPath: "root", root: detached, context: .init(sceneIdentifier: "gone")))
    }

    func testDefaultWindowIgnoresSDKKeyInHostScope() {
        let candidates: [HostInspectionUIKit.WindowCandidate] = [
            .init(appAgentOwned: false, visible: true, key: false, normalLevel: true),
            .init(appAgentOwned: true, visible: true, key: true, normalLevel: false)
        ]
        XCTAssertEqual(HostInspectionUIKit.defaultWindowIndex(candidates: candidates, scope: .host), 0)
        XCTAssertEqual(HostInspectionUIKit.defaultWindowIndex(candidates: candidates, scope: .appagent), 1)
        XCTAssertEqual(HostInspectionUIKit.defaultWindowIndex(candidates: candidates, scope: .all), 1)
    }

    func testStableHandlesNeverRecycleOrRetainWindows() {
        let registry = HostInspectionHandleRegistry<NSObject>()
        var removed: NSObject? = NSObject()
        weak var weakRemoved = removed
        let old = registry.handle(for: removed!)
        let retained = NSObject()
        let stable = registry.handle(for: retained)
        removed = nil
        XCTAssertNil(weakRemoved)
        XCTAssertNil(registry.object(for: old))
        let replacement = NSObject()
        let fresh = registry.handle(for: replacement)
        XCTAssertGreaterThan(fresh, stable)
        XCTAssertEqual(registry.handle(for: retained), stable)
        XCTAssertTrue(registry.object(for: stable) === retained)
    }

    func testScreenshotFailsClosedForMixedSubtreeButCapturesSafeSibling() throws {
        let (root, sdkRoot, _, visible) = mixedTree()
        XCTAssertThrowsError(try ScreenshotTool.render(root, maxPixelWidth: 64))
        XCTAssertThrowsError(try ScreenshotTool.render(sdkRoot, maxPixelWidth: 64))
        XCTAssertNil(HostInspectionUIKit.screenshotRejection(for: root, context: all))
        XCTAssertNil(HostInspectionUIKit.screenshotRejection(for: sdkRoot, context: sdk))
        let image = try ScreenshotTool.render(visible, maxPixelWidth: 64)
        XCTAssertNotNil(image.pngData())
        XCTAssertLessThanOrEqual(image.size.width * image.scale, 64.01)
        sdkRoot.isHidden = true
        XCTAssertThrowsError(try ScreenshotTool.render(root, maxPixelWidth: 64), "Hidden SDK views still require exclusion")
        XCTAssertThrowsError(try ScreenshotTool.render(UIVisualEffectView(effect: UIBlurEffect(style: .light)), maxPixelWidth: 64))
    }

    func testToolsForwardImmutableContextAndDetailNeverWidensScope() async throws {
        let provider = ScopeRecordingRuntimeProvider()
        let tool = RuntimeInspectTool(provider: provider)
        let session = AISession(id: UUID().uuidString)
        session.inspectionSceneIdentifier = "scene-A"
        session.decisionResponders = DecisionResponderCentral()
        let operations = ["ui_hierarchy", "view_tree", "view_info", "view_set", "view_invoke",
                          "class_list", "method_list", "property_list", "property_value", "property_set", "invoke"]
        for operation in operations {
            _ = try await tool.execute(arguments: [
                "op": .string(operation), "detail": .string("full"), "path": .string("0"),
                "key": .string("tag"), "keyPath": .string("tag"), "value": .string("1"),
                "class": .string("UIView"), "filter": .string("UI"), "selector": .string("setNeedsLayout")
            ], session: session)
        }
        let recorded = await provider.contexts
        XCTAssertEqual(recorded.count, operations.count)
        XCTAssertTrue(recorded.allSatisfy { $0 == HostInspectionContext(sceneIdentifier: "scene-A") })
        do {
            _ = try await tool.execute(arguments: ["op": .string("ui_hierarchy"), "detail": .string("full"),
                                                  "scope": .string("all")], session: session)
            XCTFail("Scope authorization must precede provider invocation")
        } catch {}
        let screenshot = try await ScreenshotTool().execute(arguments: ["scope": .string("all")], session: session)
        if case .error(let message) = screenshot {
            XCTAssertEqual(message, HostInspectionError.denied.localizedDescription)
        } else {
            XCTFail("Screenshot must reject unauthorized scope with an error output")
        }
        let afterDenial = await provider.contexts
        XCTAssertEqual(afterDenial, recorded)
    }
}

private final class ScopeSDKController: AppAgentViewController {
    override func loadView() { view = UIView() }
    override func viewDidLoad() {} // Isolate ownership from overlay setup/session tasks.
}

private final class ScopeLinkView: UIView {
    @objc var link: NSObject?
    @objc var payload: Any?
}

private final class AppAgentHostNamedView: UIView {}

private final class ScopeHostBox<Value> {}

private final class ScopeProbeView: UIView {
    var reads = 0
    var descriptions = 0
    @objc var secret: String { reads += 1; return "SDK-PRIVATE" }
    override var description: String { descriptions += 1; return "SDK-PRIVATE-DESCRIPTION" }
}

private actor ScopeRecordingRuntimeProvider: RuntimeInspectProvider {
    var contexts: [HostInspectionContext] = []
    private func record(_ context: HostInspectionContext) -> String { contexts.append(context); return "OK." }
    func uiHierarchy(context: HostInspectionContext) async -> String { record(context) }
    func classList(matching filter: String?, context: HostInspectionContext) async -> [String] { [record(context)] }
    func methodList(ofClass className: String, context: HostInspectionContext) async -> [String] { [record(context)] }
    func propertyList(ofClass className: String, context: HostInspectionContext) async -> [String] { [record(context)] }
    func propertyValue(keyPath: String, ofClass className: String?, context: HostInspectionContext) async -> String? { record(context) }
    func setPropertyValue(keyPath: String, value: String, ofClass className: String?, context: HostInspectionContext) async -> String { record(context) }
    func invoke(className: String, selector: String, argumentsJSON: String, context: HostInspectionContext) async -> String { record(context) }
    func viewSubtree(path: String, maxDepth: Int, context: HostInspectionContext) async -> String { record(context) }
    func viewInfo(path: String, context: HostInspectionContext) async -> String { record(context) }
    func setViewValue(path: String, key: String, value: String, context: HostInspectionContext) async -> String { record(context) }
    func invokeOnView(path: String, selector: String, argumentsJSON: String, context: HostInspectionContext) async -> String { record(context) }
}
#endif
