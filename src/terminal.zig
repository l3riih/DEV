const std = @import("std");
const ChildProcess = std.process.Child;
const io = std.io;

/// Estructura para representar el resultado de un comando ejecutado
pub const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32, // Usando i32 para poder representar valores negativos
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CommandResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// Estructura para almacenar información del sistema
pub const SystemInfo = struct {
    os_name: []const u8,
    os_version: []const u8,
    kernel_version: []const u8,
    desktop_env: []const u8,
    shell: []const u8,
    memory_total: []const u8,
    cpu_info: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SystemInfo {
        return SystemInfo{
            .os_name = try getCommandOutput(allocator, "cat /etc/os-release | grep -w NAME | cut -d= -f2 | tr -d '\"'"),
            .os_version = try getCommandOutput(allocator, "cat /etc/os-release | grep -w VERSION | cut -d= -f2 | tr -d '\"'"),
            .kernel_version = try getCommandOutput(allocator, "uname -r"),
            .desktop_env = try getCommandOutput(allocator, "echo $XDG_CURRENT_DESKTOP || echo 'Unknown'"),
            .shell = try getCommandOutput(allocator, "basename $SHELL"),
            .memory_total = try getCommandOutput(allocator, "free -h | awk '/^Mem:/ {print $2}'"),
            .cpu_info = try getCommandOutput(allocator, "grep -m 1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SystemInfo) void {
        self.allocator.free(self.os_name);
        self.allocator.free(self.os_version);
        self.allocator.free(self.kernel_version);
        self.allocator.free(self.desktop_env);
        self.allocator.free(self.shell);
        self.allocator.free(self.memory_total);
        self.allocator.free(self.cpu_info);
    }

    pub fn getFormattedInfo(self: *const SystemInfo) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();
        try writer.print(
            \\Sistema: {s} {s}
            \\Kernel: {s}
            \\Escritorio: {s}
            \\Shell: {s}
            \\Memoria: {s}
            \\CPU: {s}
            \\
        , .{
            self.os_name,        self.os_version,
            self.kernel_version, self.desktop_env,
            self.shell,          self.memory_total,
            self.cpu_info,
        });

        return buffer.toOwnedSlice();
    }
};

/// Ejecuta un comando en la terminal y devuelve su salida
pub fn executeCommand(allocator: std.mem.Allocator, command: []const u8) !CommandResult {
    // Crea una lista de argumentos para el shell
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("sh");
    try args.append("-c");
    try args.append(command);

    // Crear el proceso
    var process = ChildProcess.init(args.items, allocator);

    // Configurar redirección de la salida
    process.stdin_behavior = .Ignore;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    // Iniciar el proceso
    try process.spawn();

    // Capturar la salida estándar
    var stdout_buffer = std.ArrayList(u8).init(allocator);
    defer stdout_buffer.deinit();

    // Leer desde stdout del proceso
    const stdout_reader = process.stdout.?.reader();
    var stdout_buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try stdout_reader.read(&stdout_buf);
        if (bytes_read == 0) break;
        try stdout_buffer.appendSlice(stdout_buf[0..bytes_read]);
    }

    // Capturar la salida de error
    var stderr_buffer = std.ArrayList(u8).init(allocator);
    defer stderr_buffer.deinit();

    // Leer desde stderr del proceso
    const stderr_reader = process.stderr.?.reader();
    var stderr_buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try stderr_reader.read(&stderr_buf);
        if (bytes_read == 0) break;
        try stderr_buffer.appendSlice(stderr_buf[0..bytes_read]);
    }

    // Esperar a que el proceso termine
    const term = try process.wait();

    // Obtener el código de salida como i32 para manejar valores negativos
    const exit_code: i32 = switch (term) {
        .Exited => |code| @as(i32, code),
        else => -1,
    };

    // Duplicar las cadenas de salida para devolverlas
    const stdout_result = try allocator.dupe(u8, stdout_buffer.items);
    const stderr_result = try allocator.dupe(u8, stderr_buffer.items);

    return CommandResult{
        .stdout = stdout_result,
        .stderr = stderr_result,
        .exit_code = exit_code,
        .allocator = allocator,
    };
}

/// Función auxiliar para ejecutar comandos y obtener su salida
fn getCommandOutput(allocator: std.mem.Allocator, command: []const u8) ![]const u8 {
    const argv = [_][]const u8{ "sh", "-c", command };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Leer la salida del proceso
    const stdout = child.stdout.?;
    var read_buffer: [1024]u8 = undefined;

    while (true) {
        const bytes_read = try stdout.read(&read_buffer);
        if (bytes_read == 0) break;
        try buffer.appendSlice(read_buffer[0..bytes_read]);
    }

    // Esperar a que termine el proceso
    _ = try child.wait();

    // Eliminar espacios en blanco al final
    var result = try buffer.toOwnedSlice();
    var end: usize = result.len;
    while (end > 0 and (result[end - 1] == '\n' or result[end - 1] == '\r')) {
        end -= 1;
    }

    if (end < result.len) {
        const trimmed = try allocator.dupe(u8, result[0..end]);
        allocator.free(result);
        return trimmed;
    }

    return result;
}

/// Función para probar la ejecución de comandos
pub fn testCommandExecution(allocator: std.mem.Allocator) !void {
    const stdout = io.getStdOut().writer();

    try stdout.print("Ejecutando comando 'ls -la'...\n", .{});

    var result = try executeCommand(allocator, "ls -la");
    defer result.deinit();

    try stdout.print("\nSalida estándar:\n{s}\n", .{result.stdout});
    try stdout.print("\nSalida de error:\n{s}\n", .{result.stderr});
    try stdout.print("\nCódigo de salida: {d}\n", .{result.exit_code});
}
