const std = @import("std");
const api = @import("api.zig");
const terminal = @import("terminal.zig");

/// Define una tarea planificada para ser ejecutada
pub const TaskStep = struct {
    description: []const u8,
    command: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TaskStep) void {
        self.allocator.free(self.description);
        self.allocator.free(self.command);
    }
};

/// Define un plan compuesto de varios pasos
pub const TaskPlan = struct {
    steps: std.ArrayList(TaskStep),

    pub fn init(allocator: std.mem.Allocator) TaskPlan {
        return TaskPlan{
            .steps = std.ArrayList(TaskStep).init(allocator),
        };
    }

    pub fn deinit(self: *TaskPlan) void {
        for (self.steps.items) |*step| {
            step.deinit();
        }
        self.steps.deinit();
    }

    pub fn addStep(self: *TaskPlan, description: []const u8, command: []const u8) !void {
        const desc_copy = try self.steps.allocator.dupe(u8, description);
        const cmd_copy = try self.steps.allocator.dupe(u8, command);

        const step = TaskStep{
            .description = desc_copy,
            .command = cmd_copy,
            .allocator = self.steps.allocator,
        };

        try self.steps.append(step);
    }
};

/// Estructura para almacenar el historial de comandos y sus resultados
pub const CommandHistory = struct {
    command: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, command: []const u8, result: terminal.CommandResult) !CommandHistory {
        const cmd_copy = try allocator.dupe(u8, command);
        const stdout_copy = try allocator.dupe(u8, result.stdout);
        const stderr_copy = try allocator.dupe(u8, result.stderr);

        return CommandHistory{
            .command = cmd_copy,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
            .exit_code = result.exit_code,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandHistory) void {
        self.allocator.free(self.command);
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

/// El agente de terminal que procesa tareas en lenguaje natural
pub const TerminalAgent = struct {
    allocator: std.mem.Allocator,
    api_client: api.ApiClient,
    command_history: std.ArrayList(CommandHistory),
    system_info: ?terminal.SystemInfo,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const api_client = try api.ApiClient.init(allocator);

        // Intentar obtener información del sistema
        var sys_info: ?terminal.SystemInfo = null;
        sys_info = terminal.SystemInfo.init(allocator) catch |err| {
            std.debug.print("No se pudo obtener información del sistema: {s}\n", .{@errorName(err)});
            return Self{
                .allocator = allocator,
                .api_client = api_client,
                .command_history = std.ArrayList(CommandHistory).init(allocator),
                .system_info = null,
            };
        };

        return Self{
            .allocator = allocator,
            .api_client = api_client,
            .command_history = std.ArrayList(CommandHistory).init(allocator),
            .system_info = sys_info,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.command_history.items) |*history| {
            history.deinit();
        }
        self.command_history.deinit();

        if (self.system_info) |*info| {
            info.deinit();
        }

        self.api_client.deinit();
    }

    /// Añade un comando y su resultado al historial
    fn addToHistory(self: *Self, command: []const u8, result: terminal.CommandResult) !void {
        const history_entry = try CommandHistory.init(self.allocator, command, result);
        try self.command_history.append(history_entry);
    }

    /// Obtiene un historial formateado de comandos y resultados para enviar a la API
    fn getCommandHistoryForPrompt(self: *Self) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        const writer = buffer.writer();

        try writer.print("Historial de comandos ejecutados:\n\n", .{});

        for (self.command_history.items, 0..) |history, i| {
            try writer.print("Comando {d}: {s}\n", .{ i + 1, history.command });
            try writer.print("Salida estándar:\n{s}\n", .{history.stdout});

            if (history.exit_code != 0) {
                try writer.print("Error (código {d}):\n{s}\n", .{ history.exit_code, history.stderr });
            }

            try writer.print("\n", .{});
        }

        return try self.allocator.dupe(u8, buffer.items);
    }

    /// Procesa una tarea en lenguaje natural
    pub fn processTask(self: *Self, task_text: []const u8, writer: anytype) !void {
        // Determinar si la tarea es simple o necesita un plan
        if (self.isSimpleTask(task_text)) {
            // Para tareas simples, ejecutar directamente
            try self.executeSimpleTask(task_text, writer);
        } else {
            // Para tareas complejas, generar un plan y ejecutarlo
            try self.planAndExecuteTask(task_text, writer);
        }

        // Opcionalmente, podríamos permitir que el agente analice los resultados
        // para sugerir acciones adicionales
        try self.analyzeResults(task_text, writer);
    }

    /// Determina si una tarea es simple o compleja (actualmente simulado)
    fn isSimpleTask(self: *Self, task_text: []const u8) bool {
        _ = self;

        // Por simplicidad, consideramos tareas simples aquellas con menos de 5 palabras
        var word_count: usize = 1; // Al menos una palabra

        for (task_text) |c| {
            if (c == ' ') {
                word_count += 1;
            }
        }

        return word_count < 5;
    }

    /// Ejecuta una tarea simple directamente
    fn executeSimpleTask(self: *Self, task_text: []const u8, writer: anytype) !void {
        try writer.print("\nEjecutando tarea simple: {s}\n", .{task_text});

        // En un caso real, usaríamos la API para entender el comando necesario
        // Por ahora, simplemente tratamos el texto como un comando
        var command_result = try terminal.executeCommand(self.allocator, task_text);
        defer command_result.deinit();

        // Almacenar el comando y su resultado en el historial
        try self.addToHistory(task_text, command_result);

        try writer.print("\nResultado:\n{s}\n", .{command_result.stdout});

        if (command_result.exit_code != 0) {
            try writer.print("\nError (código {d}):\n{s}\n", .{ command_result.exit_code, command_result.stderr });
        }
    }

    /// Genera un plan y ejecuta una tarea compleja
    fn planAndExecuteTask(self: *Self, task_text: []const u8, writer: anytype) !void {
        try writer.print("\nAnalizando tarea compleja: {s}\n", .{task_text});

        // Generar un plan para la tarea
        var plan = try self.generateTaskPlan(task_text);
        defer plan.deinit();

        // Mostrar el plan
        try writer.print("\nPlan generado con {d} pasos:\n", .{plan.steps.items.len});

        for (plan.steps.items, 0..) |step, i| {
            try writer.print("\nPaso {d}: {s}\n", .{ i + 1, step.description });
            try writer.print("Comando: {s}\n", .{step.command});

            // Preguntar al usuario si desea ejecutar este paso (Enter = Sí)
            try writer.print("\n¿Ejecutar este paso? (S/n): ", .{});

            const stdin = std.io.getStdIn().reader();
            var buffer: [2]u8 = undefined;
            if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |input| {
                const choice = std.mem.trim(u8, input, &std.ascii.whitespace);

                // Si la entrada está vacía o es "s", ejecutar el paso
                if (choice.len == 0 or std.mem.eql(u8, choice, "s") or std.mem.eql(u8, choice, "S")) {
                    // Ejecutar el comando del paso
                    var result = try terminal.executeCommand(self.allocator, step.command);
                    defer result.deinit();

                    // Almacenar el comando y su resultado en el historial
                    try self.addToHistory(step.command, result);

                    try writer.print("\nResultado:\n{s}\n", .{result.stdout});

                    if (result.exit_code != 0) {
                        try writer.print("\nError (código {d}):\n{s}\n", .{ result.exit_code, result.stderr });

                        // Preguntar si continuar con el plan a pesar del error (Enter = Sí)
                        try writer.print("\nEl paso falló. ¿Continuar con el plan? (S/n): ", .{});

                        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |continue_input| {
                            const continue_choice = std.mem.trim(u8, continue_input, &std.ascii.whitespace);

                            // Solo cancelar si se ingresa explícitamente "n" o "N"
                            if (continue_choice.len > 0 and (std.mem.eql(u8, continue_choice, "n") or std.mem.eql(u8, continue_choice, "N"))) {
                                try writer.print("\nPlan cancelado por el usuario.\n", .{});
                                return;
                            }
                        }
                    }

                    // Preguntar si desea ajustar el plan basado en el resultado (Enter = Sí)
                    if (i < plan.steps.items.len - 1) {
                        try writer.print("\n¿Desea ajustar el plan basado en este resultado? (S/n): ", .{});

                        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |adjust_input| {
                            const adjust_choice = std.mem.trim(u8, adjust_input, &std.ascii.whitespace);

                            // Si la entrada está vacía o es "s", ajustar el plan
                            if (adjust_choice.len == 0 or std.mem.eql(u8, adjust_choice, "s") or std.mem.eql(u8, adjust_choice, "S")) {
                                // Regenerar el plan basado en el historial de comandos
                                try writer.print("\nAjustando el plan...\n", .{});

                                // Obtener el historial formateado para enviarlo a la API
                                const history_text = try self.getCommandHistoryForPrompt();
                                defer self.allocator.free(history_text);

                                // Crear un nuevo plan
                                var new_plan = try self.regeneratePlan(task_text, history_text, i + 1, plan.steps.items.len);
                                defer new_plan.deinit();

                                // Reemplazar los pasos restantes del plan actual
                                if (new_plan.steps.items.len > 0) {
                                    // Eliminar los pasos restantes del plan actual
                                    while (plan.steps.items.len > i + 1) {
                                        var last = plan.steps.pop();
                                        last.deinit();
                                    }

                                    // Añadir los nuevos pasos al plan
                                    for (new_plan.steps.items) |new_step| {
                                        try plan.addStep(new_step.description, new_step.command);
                                    }

                                    try writer.print("\nPlan actualizado con {d} nuevos pasos.\n", .{new_plan.steps.items.len});
                                } else {
                                    try writer.print("\nNo se pudieron generar nuevos pasos. Continuando con el plan original.\n", .{});
                                }
                            }
                        }
                    }
                } else {
                    try writer.print("\nPaso omitido.\n", .{});
                }
            }
        }

        try writer.print("\nPlan completado.\n", .{});
    }

    /// Analiza los resultados del historial de comandos utilizando la API de Gemini
    fn analyzeResults(self: *Self, task_text: []const u8, writer: anytype) !void {
        if (self.command_history.items.len == 0) {
            return; // No hay historial para analizar
        }

        try writer.print("\n¿Desea que el agente analice los resultados? (S/n): ", .{});

        const stdin = std.io.getStdIn().reader();
        var buffer: [2]u8 = undefined;
        if (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) |input| {
            const choice = std.mem.trim(u8, input, &std.ascii.whitespace);

            // Si la entrada está vacía o es "s", analizar los resultados
            if (choice.len == 0 or std.mem.eql(u8, choice, "s") or std.mem.eql(u8, choice, "S")) {
                try writer.print("\nAnalizando resultados...\n", .{});

                // Obtener el historial formateado para enviarlo a la API
                const history_text = try self.getCommandHistoryForPrompt();
                defer self.allocator.free(history_text);

                // Construir el prompt para la API
                var prompt_buffer = std.ArrayList(u8).init(self.allocator);
                defer prompt_buffer.deinit();

                // Base del prompt
                try prompt_buffer.writer().print("Eres un asistente de terminal experto en Linux. ", .{});

                // Incluir información del sistema si está disponible
                if (self.system_info) |*info| {
                    const system_info_text = try info.getFormattedInfo();
                    defer self.allocator.free(system_info_text);

                    try prompt_buffer.writer().print("Tengo la siguiente información sobre el sistema Linux del usuario:\n{s}\n\n", .{system_info_text});
                }

                // Continuar con el resto del prompt
                try prompt_buffer.writer().print("Analiza los resultados de estos comandos y proporciona una interpretación clara y concisa. " ++
                    "Si detectas errores, explica su posible causa y sugiere soluciones compatibles con el sistema del usuario. " ++
                    "Si todo está correcto, confirma el éxito y sugiere posibles pasos adicionales si son relevantes. " ++
                    "Tarea original: \"{s}\"\n\n{s}", .{ task_text, history_text });

                // Enviar el prompt a la API
                try writer.print("\nEnviando resultados a Gemini para análisis...\n", .{});

                var response = self.api_client.sendPrompt(prompt_buffer.items) catch |err| {
                    try writer.print("\nError al conectar con la API: {s}\n", .{@errorName(err)});
                    try writer.print("\nAnalizando localmente: Los comandos se han ejecutado. Revise la salida para más detalles.\n", .{});
                    return;
                };
                defer response.deinit();

                try writer.print("\nAnálisis:\n{s}\n", .{response.content});
            }
        }
    }

    /// Genera un plan para una tarea compleja utilizando la API de Gemini
    fn generateTaskPlan(self: *Self, task_text: []const u8) !TaskPlan {
        var plan = TaskPlan.init(self.allocator);

        // Construir el prompt para la API
        var prompt_buffer = std.ArrayList(u8).init(self.allocator);
        defer prompt_buffer.deinit();

        // Base del prompt
        try prompt_buffer.writer().print("Eres un asistente de terminal experto en Linux que genera planes para ejecutar tareas. ", .{});

        // Incluir información del sistema si está disponible
        if (self.system_info) |*info| {
            const system_info_text = try info.getFormattedInfo();
            defer self.allocator.free(system_info_text);

            try prompt_buffer.writer().print("Tengo la siguiente información sobre el sistema Linux del usuario:\n{s}\n\n", .{system_info_text});
        }

        // Continuar con el resto del prompt
        try prompt_buffer.writer().print("Genera un plan detallado y específico paso a paso para realizar exactamente la siguiente tarea en Linux: \"{s}\". " ++
            "Para cada paso, indica una descripción clara y el comando exacto a ejecutar. " ++
            "Proporciona solo los comandos que son necesarios y seguros para completar la tarea. " ++
            "Asegúrate de que cada comando sea relevante para la tarea solicitada y compatible con el sistema del usuario. " ++
            "Responde SIEMPRE en formato JSON con un array de objetos, cada uno con exactamente los campos 'description' y 'command'. " ++
            "Ejemplo de formato: [{{\"description\": \"Listar archivos\", \"command\": \"ls -la\"}}]", .{task_text});

        // Enviar el prompt a la API
        var response = self.api_client.sendPrompt(prompt_buffer.items) catch |err| {
            std.debug.print("Error al conectar con la API: {s}\n", .{@errorName(err)});

            // Crear un plan específico incluso sin conexión API
            var desc_buffer = std.ArrayList(u8).init(self.allocator);
            defer desc_buffer.deinit();

            try desc_buffer.writer().print("Analizar la tarea solicitada", .{});
            try plan.addStep(desc_buffer.items, "echo \"Analizando tarea...\"");

            var cmd_buffer = std.ArrayList(u8).init(self.allocator);
            defer cmd_buffer.deinit();

            try cmd_buffer.writer().print("Ejecutar comando inferido localmente", .{});
            try plan.addStep(cmd_buffer.items, task_text);

            return plan;
        };
        defer response.deinit();

        // Intentar analizar la respuesta JSON
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.content, .{}) catch |err| {
            std.debug.print("Error al analizar el JSON de respuesta: {s}\n", .{@errorName(err)});
            std.debug.print("Respuesta recibida: {s}\n", .{response.content});

            // Intentar extraer comandos de texto plano si no es JSON válido
            try self.extractCommandsFromText(&plan, response.content, task_text);

            // Verificar si se añadieron pasos
            if (plan.steps.items.len == 0) {
                try plan.addStep("Ejecutar el comando solicitado", task_text);
            }

            return plan;
        };
        defer parsed.deinit();

        // Verificar que la respuesta es un array
        if (parsed.value != .array) {
            std.debug.print("La respuesta no es un array JSON: {s}\n", .{response.content});

            // Intentar extraer comandos del texto plano
            try self.extractCommandsFromText(&plan, response.content, task_text);

            // Verificar si se añadieron pasos
            if (plan.steps.items.len == 0) {
                try plan.addStep("Ejecutar el comando solicitado", task_text);
            }

            return plan;
        }

        // Procesar los pasos del plan
        for (parsed.value.array.items) |step_value| {
            if (step_value != .object) continue;

            // Extraer descripción y comando
            const description = if (step_value.object.get("description")) |desc|
                if (desc == .string) desc.string else "Paso del plan"
            else
                "Paso del plan";

            const command = if (step_value.object.get("command")) |cmd|
                if (cmd == .string) cmd.string else task_text
            else
                task_text;

            // Añadir el paso al plan solo si el comando es relevante
            if (!std.mem.eql(u8, command, task_text)) {
                try plan.addStep(description, command);
            } else {
                // Si el comando es igual a la tarea, verificar si es un comando válido
                if (self.isLikelyCommand(task_text)) {
                    try plan.addStep(description, command);
                }
            }
        }

        // Si no se añadió ningún paso, intentar extraer comandos del texto
        if (plan.steps.items.len == 0) {
            try self.extractCommandsFromText(&plan, response.content, task_text);

            // Si aún no hay pasos, crear un plan específico
            if (plan.steps.items.len == 0) {
                try plan.addStep("Ejecutar el comando solicitado", task_text);
            }
        }

        return plan;
    }

    /// Regenera el plan basado en los resultados de los comandos ejecutados previamente
    fn regeneratePlan(self: *Self, task_text: []const u8, history_text: []const u8, current_step: usize, total_steps: usize) !TaskPlan {
        var plan = TaskPlan.init(self.allocator);

        // Construir el prompt para la API
        var prompt_buffer = std.ArrayList(u8).init(self.allocator);
        defer prompt_buffer.deinit();

        // Base del prompt
        try prompt_buffer.writer().print("Eres un asistente de terminal experto en Linux que mejora planes de ejecución. ", .{});

        // Incluir información del sistema si está disponible
        if (self.system_info) |*info| {
            const system_info_text = try info.getFormattedInfo();
            defer self.allocator.free(system_info_text);

            try prompt_buffer.writer().print("Tengo la siguiente información sobre el sistema Linux del usuario:\n{s}\n\n", .{system_info_text});
        }

        // Continuar con el resto del prompt
        try prompt_buffer.writer().print("Estás ejecutando un plan para la tarea: \"{s}\". " ++
            "Has completado {d} de {d} pasos del plan original. " ++
            "Basado en los resultados de los comandos ejecutados hasta ahora, genera un nuevo plan para completar la tarea. " ++
            "Aquí está el historial de comandos ejecutados y sus resultados:\n\n{s}\n\n" ++
            "Proporciona SOLO los pasos RESTANTES que faltan para completar la tarea. " ++
            "Adapta el plan basado en los resultados de los comandos anteriores, especialmente si hubo errores. " ++
            "Responde SIEMPRE en formato JSON con un array de objetos, cada uno con exactamente los campos 'description' y 'command'. " ++
            "Ejemplo de formato: [{{\"description\": \"Siguiente paso\", \"command\": \"comando-adaptado\"}}]", .{ task_text, current_step, total_steps, history_text });

        // Enviar el prompt a la API
        var response = self.api_client.sendPrompt(prompt_buffer.items) catch |err| {
            std.debug.print("Error al conectar con la API para regenerar el plan: {s}\n", .{@errorName(err)});
            return plan; // Devolver un plan vacío, se mantendrá el original
        };
        defer response.deinit();

        // Intentar analizar la respuesta JSON
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.content, .{}) catch |err| {
            std.debug.print("Error al analizar el JSON de respuesta para el plan regenerado: {s}\n", .{@errorName(err)});

            // Intentar extraer comandos de texto plano
            try self.extractCommandsFromText(&plan, response.content, task_text);
            return plan;
        };
        defer parsed.deinit();

        // Verificar que la respuesta es un array
        if (parsed.value != .array) {
            std.debug.print("La respuesta para el plan regenerado no es un array JSON\n", .{});

            // Intentar extraer comandos del texto plano
            try self.extractCommandsFromText(&plan, response.content, task_text);
            return plan;
        }

        // Procesar los pasos del plan
        for (parsed.value.array.items) |step_value| {
            if (step_value != .object) continue;

            // Extraer descripción y comando
            const description = if (step_value.object.get("description")) |desc|
                if (desc == .string) desc.string else "Paso del plan"
            else
                "Paso del plan";

            const command = if (step_value.object.get("command")) |cmd|
                if (cmd == .string) cmd.string else ""
            else
                "";

            // Añadir solo pasos con comandos válidos
            if (command.len > 0) {
                try plan.addStep(description, command);
            }
        }

        return plan;
    }

    /// Determina si un texto se parece a un comando de terminal
    fn isLikelyCommand(self: *Self, text: []const u8) bool {
        _ = self;

        // Lista de comandos comunes de Linux
        const common_commands = [_][]const u8{ "ls", "cd", "mkdir", "rm", "cp", "mv", "cat", "grep", "find", "echo", "touch", "chmod", "chown", "ps", "top", "kill", "sudo", "apt", "yum", "pacman", "systemctl", "journalctl", "git", "curl", "wget", "ssh", "scp", "tar", "zip", "unzip", "df", "du", "free", "ping", "ifconfig", "ip", "netstat", "ss", "uname", "whoami", "who" };

        // Verificar si el texto comienza con alguno de los comandos comunes
        for (common_commands) |cmd| {
            if (std.mem.startsWith(u8, text, cmd)) {
                // Verificar que es el comando completo o seguido de un espacio
                if (text.len == cmd.len or (text.len > cmd.len and text[cmd.len] == ' ')) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Intenta extraer comandos de un texto no estructurado
    fn extractCommandsFromText(self: *Self, plan: *TaskPlan, text: []const u8, _: []const u8) !void {
        var lines = std.mem.split(u8, text, "\n");

        var in_command_block = false;
        var current_description: []const u8 = "Paso del plan";

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            // Saltar líneas vacías
            if (trimmed.len == 0) continue;

            // Buscar líneas que parezcan descripciones
            if (std.mem.indexOf(u8, trimmed, ":") != null and
                !in_command_block and
                trimmed.len < 100)
            {
                current_description = trimmed;
                continue;
            }

            // Detectar bloques de código
            if (std.mem.eql(u8, trimmed, "```") or
                std.mem.startsWith(u8, trimmed, "```"))
            {
                in_command_block = !in_command_block;
                continue;
            }

            // Si estamos dentro de un bloque de código o la línea parece un comando
            if (in_command_block or self.isLikelyCommand(trimmed)) {
                try plan.addStep(current_description, trimmed);
                current_description = "Paso del plan";
            }
        }
    }
};
