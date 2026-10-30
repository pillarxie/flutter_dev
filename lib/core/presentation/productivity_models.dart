class RunProfile {
  const RunProfile({
    required this.id,
    required this.name,
    required this.projectPath,
    this.sdkPath,
    this.deviceId,
    this.platform,
    this.entrypoint = 'lib/main.dart',
    this.mode = 'debug',
    this.flavor,
    this.dartDefines = const [],
    this.environment = const {},
    this.toolArgs = const [],
    this.attachUri,
    this.noDebug = false,
    this.environmentText,
    this.toolArgsText,
  });
  final String id, name, projectPath, entrypoint, mode;
  final String? sdkPath, deviceId, platform, flavor, attachUri;
  final List<String> dartDefines, toolArgs;
  final Map<String, String> environment;
  final bool noDebug;
  final String? environmentText, toolArgsText;
}

class ProjectRunState {
  const ProjectRunState({
    required this.projectPath,
    this.draft,
    this.lastRun,
    this.selectedProfileId,
    this.autoReload = false,
  });
  final String projectPath;
  final RunProfile? draft, lastRun;
  final String? selectedProfileId;
  final bool autoReload;
}

class WorkspacePreferences {
  const WorkspacePreferences({
    this.runProfiles = const [],
    this.projectStates = const [],
    this.editorExecutable = 'code',
    this.editorArguments = const ['--goto', '{file}:{line}:{column}'],
  });
  final List<RunProfile> runProfiles;
  final List<ProjectRunState> projectStates;
  final String editorExecutable;
  final List<String> editorArguments;
}

class TestSelection {
  const TestSelection({required this.path, this.name});
  final String path;
  final String? name;
}

class TestRunConfig {
  const TestRunConfig({
    required this.projectPath,
    this.sdkPath,
    this.selections = const [],
  });
  final String projectPath;
  final String? sdkPath;
  final List<TestSelection> selections;
}

class TestResult {
  const TestResult({
    required this.id,
    required this.path,
    required this.name,
    required this.status,
    this.error,
    this.stackTrace,
  });
  final String id, path, name, status;
  final String? error, stackTrace;
}

class TestRunSnapshot {
  const TestRunSnapshot({
    required this.id,
    required this.projectPath,
    required this.state,
    this.tests = const [],
    this.passed = 0,
    this.failed = 0,
    this.skipped = 0,
    this.exitCode,
    this.error,
  });
  final String id, projectPath, state;
  final List<TestResult> tests;
  final int passed, failed, skipped;
  final int? exitCode;
  final String? error;
  bool get active => const ['starting', 'running', 'stopping'].contains(state);
}
