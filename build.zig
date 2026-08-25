const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// Die build.zig zeigt seit 0.61.8 nur noch auf module.R4MF, statt Name,
/// Typ beziehungsweise Rolle und Metadaten ein zweites Mal hinzuschreiben.
/// Damit gibt es hier nichts mehr, was vom Manifest abweichen koennte.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const queue_tests_module = b.createModule(.{
        .root_source_file = b.path("src/queue_state.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const queue_tests = b.addTest(.{ .root_module = queue_tests_module });
    const run_queue_tests = b.addRunArtifact(queue_tests);

    const work_gate_tests_module = b.createModule(.{
        .root_source_file = b.path("src/work_gate.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const work_gate_tests = b.addTest(.{ .root_module = work_gate_tests_module });
    const run_work_gate_tests = b.addRunArtifact(work_gate_tests);

    const test_step = b.step("test", "Run AC97 descriptor queue ownership tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_queue_tests.step);
    test_step.dependOn(&run_work_gate_tests.step);
}
