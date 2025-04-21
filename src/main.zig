const std = @import("std");
const root = @import("root.zig");

// Módulos para el agente de IA
const api = @import("api.zig");
const terminal = @import("terminal.zig");
const agent = @import("agent.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Inicializar el agente
    var terminalAgent = try agent.TerminalAgent.init(allocator);
    defer terminalAgent.deinit();

    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    // Banner de inicio
    try stdout.print("Terminal Agent IA - Powered by Gemini\n", .{});
    try stdout.print("Ingresa tus tareas en lenguaje natural. Escribe 'salir' para terminar.\n\n", .{});

    var buffer: [1024]u8 = undefined;
    while (true) {
        try stdout.print("> ", .{});
        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |input| {
            const trimmed_input = std.mem.trim(u8, input, &std.ascii.whitespace);

            // Verificar si el usuario quiere salir
            if (std.mem.eql(u8, trimmed_input, "salir")) {
                break;
            }

            // Procesar la tarea con el agente
            try terminalAgent.processTask(trimmed_input, stdout);
        } else {
            break;
        }
    }

    try stdout.print("¡Hasta luego!\n", .{});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
