import 'dart:async';

import 'productivity_models.dart';
export 'productivity_models.dart';

class Project {
  const Project({
    required this.name,
    required this.path,
    this.entrypoint = 'lib/main.dart',
    this.platforms = const [],
  });
  final String name, path, entrypoint;
  final List<String> platforms;
}

class ProjectGitInfo {
  const ProjectGitInfo({
    required this.repositoryRoot,
    this.currentBranch,
    this.headCommit,
    this.branches = const [],
  });
  final String repositoryRoot;
  final String? currentBranch, headCommit;
  final List<String> branches;

  String get label =>
      currentBranch ??
      (headCommit == null
          ? '尚无提交'
          : '游离 HEAD · ${headCommit!.substring(0, headCommit!.length.clamp(0, 7))}');
}

class Sdk {
  const Sdk({
    required this.path,
    required this.flutterVersion,
    required this.dartVersion,
    required this.source,
    this.fallbackReason,
  });
  final String path, flutterVersion, dartVersion, source;
  final String? fallbackReason;
}

class AppSettings {
  const AppSettings({
    this.defaultSdkPath,
    this.themeMode = 'light',
    this.buildPresets = const [],
    this.projects = const [],
    this.selectedProjectPath,
    this.workspacePreferences = const WorkspacePreferences(),
  });
  final String? defaultSdkPath;
  final String themeMode;
  final List<BuildPreset> buildPresets;
  final List<Project> projects;
  final String? selectedProjectPath;
  final WorkspacePreferences workspacePreferences;
}

class BuildPreset {
  const BuildPreset({
    required this.id,
    required this.name,
    required this.target,
    this.args = const [],
    this.outputDirectory,
  });
  final String id, name, target;
  final List<String> args;
  final String? outputDirectory;
}

class BuildConfig {
  const BuildConfig({
    required this.projectPath,
    this.sdkPath,
    required this.target,
    this.args = const [],
    this.outputDirectory,
  });
  final String projectPath, target;
  final String? sdkPath, outputDirectory;
  final List<String> args;
}

class BuildVersion {
  const BuildVersion({this.buildName, this.buildNumber});
  final String? buildName, buildNumber;

  String get label => buildName == null && buildNumber == null
      ? '未配置版本'
      : '${buildName ?? '未配置'}+${buildNumber ?? '未配置'}';
}

class BuildSnapshot {
  const BuildSnapshot({
    required this.id,
    required this.projectPath,
    required this.state,
    required this.target,
    this.outputDirectory,
    this.error,
    this.exitCode,
    this.version,
  });
  final String id, projectPath, state, target;
  final String? outputDirectory, error;
  final int? exitCode;
  final BuildVersion? version;
  bool get active => const ['starting', 'running', 'stopping'].contains(state);
}

class Device {
  const Device({
    required this.id,
    required this.name,
    required this.platform,
    this.available = true,
    this.isEmulator = false,
  });
  final String id, name, platform;
  final bool available, isEmulator;
}

class Emulator {
  const Emulator({
    required this.id,
    required this.name,
    required this.platform,
  });
  final String id, name, platform;
}

class RunConfig {
  const RunConfig({
    required this.sdkPath,
    required this.projectPath,
    required this.deviceId,
    this.entrypoint = 'lib/main.dart',
    this.mode = 'debug',
    this.flavor,
    this.attachUri,
    this.dartDefines = const [],
    this.env = const {},
    this.toolArgs = const [],
    this.noDebug = false,
    this.sdkPreference,
  });
  final String sdkPath, projectPath, deviceId, entrypoint, mode;
  final String? flavor, attachUri;
  final List<String> dartDefines, toolArgs;
  final Map<String, String> env;
  final bool noDebug;
  // The submitted SDK choice; empty means automatic. The core resolves it again
  // at launch, while sdkPath records the verified path shown in the UI.
  final String? sdkPreference;
}

class Session {
  const Session({
    required this.id,
    required this.generation,
    required this.state,
    required this.projectPath,
    required this.deviceId,
    required this.mode,
    this.sequence = 0,
    this.operation,
    this.serviceUri,
    this.error,
    this.capabilities = const {},
  });
  final String id, state, projectPath, deviceId, mode;
  final int generation, sequence;
  final String? operation, serviceUri, error;
  final Map<String, bool> capabilities;
  bool get active => !const ['ended', 'failed'].contains(state);
  bool get canStop => active && state != 'stopping';
  bool get canReload =>
      mode == 'debug' && state == 'running' && operation == null;
}

class LogEntry {
  const LogEntry({
    required this.id,
    required this.category,
    required this.text,
  });
  final int id;
  final String category, text;
}

class LogPage {
  const LogPage({
    required this.entries,
    required this.nextAfterId,
    this.droppedBeforeId = 0,
  });
  final List<LogEntry> entries;
  final int nextAfterId, droppedBeforeId;
}

class WorkbenchEvent {
  const WorkbenchEvent({
    required this.kind,
    this.sessionId,
    this.generation = 0,
    this.sequence = 0,
    this.session,
  });
  final String kind;
  final String? sessionId;
  final int generation, sequence;
  final Session? session;
}

abstract class WorkbenchBridge {
  Future<AppSettings> setWorkspacePreferences(
    WorkspacePreferences preferences,
  ) => Future.error(UnsupportedError('当前桥接不支持保存工作台配置'));
  Future<void> openSourceLocation(
    String projectPath,
    String path,
    int line,
    int column,
  ) => Future.error(UnsupportedError('当前桥接不支持打开源码'));
  Future<List<String>> discoverTestFiles(String projectPath) async => [];
  Future<TestRunSnapshot> startTestRun(TestRunConfig config) =>
      Future.error(UnsupportedError('当前桥接不支持测试运行'));
  Future<TestRunSnapshot> testRunSnapshot(String id) =>
      Future.error(UnsupportedError('当前桥接不支持测试运行'));
  Future<List<TestRunSnapshot>> listTestRuns() async => [];
  Future<LogPage> readTestLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
  }) async => LogPage(entries: const [], nextAfterId: afterId);
  Future<void> stopTestRun(String id) =>
      Future.error(UnsupportedError('当前桥接不支持停止测试'));
  Stream<WorkbenchEvent> get events;
  Future<AppSettings> getAppSettings();
  Future<AppSettings> setDefaultSdk(String? path);
  Future<AppSettings> setThemeMode(String mode);
  Future<AppSettings> setBuildPresets(List<BuildPreset> presets);
  Future<AppSettings> setWorkspaceProjects(
    List<Project> projects,
    String? selectedProjectPath,
  );
  Future<BuildSnapshot> startBuild(BuildConfig config);
  Future<BuildVersion> readBuildVersion(String projectPath, List<String> args);
  Future<List<BuildSnapshot>> listBuilds();
  Future<BuildSnapshot> buildSnapshot(String id);
  Future<LogPage> readBuildLogs(String id, {int afterId = 0, int limit = 200});
  Future<void> stopBuild(String id);
  Future<void> openBuildOutput(String id);
  Future<List<Project>> discoverProjects(String root);
  Future<ProjectGitInfo?> projectGitInfo(String projectPath) async => null;
  Future<ProjectGitInfo> switchProjectBranch(
    String projectPath,
    String branch,
  ) => Future.error(UnsupportedError('当前桥接不支持切换 Git 分支'));
  Future<Sdk> resolveSdk(String projectPath, String? explicitPath);
  Future<List<Device>> listDevices(String sdkPath);
  Future<List<Emulator>> listEmulators(String sdkPath);
  Future<void> launchEmulator(String sdkPath, String emulatorId);
  Future<Session> startSession(RunConfig config);
  Future<void> stopSession(String id);
  Future<void> reload(String id);
  Future<void> restart(String id);
  Future<List<Session>> listSessions();
  Future<LogPage> readLogs(
    String id, {
    int afterId = 0,
    int limit = 200,
    String query = '',
  });
  Future<Map<String, dynamic>> debuggerRequest(
    String id,
    String command,
    Map<String, dynamic> args,
  );
  Future<Map<String, dynamic>> networkRequest(
    String id,
    String method,
    Map<String, dynamic> args,
  );
  Future<String> openDevTools(String sessionId, String module);
  Future<void> closeDevTools(String sessionId);
  Future<String> readSource(String path);
  Future<void> shutdown();
}
