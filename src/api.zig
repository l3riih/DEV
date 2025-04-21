const std = @import("std");
const net = std.net;
const http = std.http;
const Uri = std.Uri;
const json = std.json;

/// Estructura que representa una respuesta de la API
pub const ApiResponse = struct {
    content: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ApiResponse) void {
        self.allocator.free(self.content);
    }
};

/// Cliente para comunicarse con la API de Gemini
pub const ApiClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const base_url = try allocator.dupe(u8, "https://text.pollinations.ai");

        return Self{
            .allocator = allocator,
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.base_url);
    }

    /// Envía una solicitud a la API y devuelve la respuesta
    pub fn sendPrompt(self: *Self, prompt: []const u8) !ApiResponse {
        // Construir la URL de la solicitud
        var url_buffer = std.ArrayList(u8).init(self.allocator);
        defer url_buffer.deinit();

        // Usar el endpoint /openai que es compatible con OpenAI para peticiones POST
        try url_buffer.appendSlice(self.base_url);
        try url_buffer.appendSlice("/openai");

        // Escapar comillas dobles en el prompt
        var escaped_prompt = std.ArrayList(u8).init(self.allocator);
        defer escaped_prompt.deinit();

        for (prompt) |c| {
            if (c == '"') {
                try escaped_prompt.appendSlice("\\\"");
            } else if (c == '\\') {
                try escaped_prompt.appendSlice("\\\\");
            } else {
                try escaped_prompt.append(c);
            }
        }

        // Construir el JSON directamente como una cadena
        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();

        try json_buffer.writer().print("{{\"model\":\"openai\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", .{
            escaped_prompt.items,
        });

        // Realizar la solicitud HTTP POST con el cuerpo JSON
        return try self.makeHttpPostRequest(url_buffer.items, json_buffer.items);
    }

    // Codificar una cadena para URL
    fn urlEncode(_: *Self, input: []const u8, buffer: *std.ArrayList(u8)) !void {
        for (input) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
                try buffer.append(c);
            } else if (c == ' ') {
                try buffer.append('+');
            } else {
                try buffer.writer().print("%{X:0>2}", .{c});
            }
        }
    }

    // Realizar una solicitud HTTP GET
    fn makeHttpRequest(self: *Self, url: []const u8) !ApiResponse {
        // Analizar la URL
        const uri = try Uri.parse(url);

        // Configurar cliente HTTP
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Preparar la solicitud
        var request = try client.request(.GET, uri, .{
            .allocator = self.allocator,
            .headers = .{},
        }, .{});
        defer request.deinit();

        // Realizar la solicitud
        try request.start();
        try request.finish();

        // Esperar la respuesta
        try request.wait();

        // Verificar que la respuesta sea exitosa
        if (request.response.status != .ok) {
            std.debug.print("Error HTTP: {d} {s}\n", .{ @intFromEnum(request.response.status), request.response.status.phrase() });
            return error.HttpRequestFailed;
        }

        // Leer el cuerpo de la respuesta
        var response_buffer = std.ArrayList(u8).init(self.allocator);
        defer response_buffer.deinit();

        var response_reader = request.reader();
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = try response_reader.read(&buffer);
            if (bytes_read == 0) break;
            try response_buffer.appendSlice(buffer[0..bytes_read]);
        }

        // Procesar la respuesta JSON (pollinations.ai devuelve JSON)
        var response_content: []u8 = undefined;

        // Intentar analizar el JSON
        var parsed = try json.parseFromSlice(json.Value, self.allocator, response_buffer.items, .{});
        defer parsed.deinit();

        // Extraer el texto de la respuesta
        // La estructura exacta depende de la API, ajustar según sea necesario
        if (parsed.value.object.get("text")) |text_value| {
            if (text_value == .string) {
                response_content = try self.allocator.dupe(u8, text_value.string);
            } else {
                // Fallback si el campo de texto no es una cadena
                response_content = try self.allocator.dupe(u8, response_buffer.items);
            }
        } else {
            // Fallback si no encontramos el campo de texto
            response_content = try self.allocator.dupe(u8, response_buffer.items);
        }

        return ApiResponse{
            .content = response_content,
            .allocator = self.allocator,
        };
    }

    // Función para hacer POST para interactuar con la API real
    fn makeHttpPostRequest(self: *Self, url: []const u8, body: []const u8) !ApiResponse {
        std.debug.print("POST request a {s} con cuerpo: {s}\n", .{ url, body });

        // En lugar de usar la biblioteca HTTP de Zig, usaremos curl
        // Primero, guardar el cuerpo en un archivo temporal para evitar problemas con caracteres especiales
        const tmp_body_path = "/tmp/gemini_request.json";
        const tmp_response_path = "/tmp/gemini_response.json";

        // Escribir el cuerpo en un archivo temporal
        {
            var file = try std.fs.cwd().createFile(tmp_body_path, .{});
            defer file.close();
            try file.writeAll(body);
        }

        // Construir el comando curl usando el archivo como entrada
        const argv = [_][]const u8{
            "curl",
            "-s",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            "Accept: application/json",
            "-d",
            "@" ++ tmp_body_path,
            url,
            "-o",
            tmp_response_path,
        };

        // Ejecutar el comando curl usando Child
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        _ = try child.spawnAndWait();

        // Leer la respuesta del archivo temporal
        var file = std.fs.cwd().openFile(tmp_response_path, .{}) catch |err| {
            std.debug.print("Error al abrir archivo de respuesta: {s}\n", .{@errorName(err)});
            return error.CouldNotReadResponse;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        if (file_size == 0) {
            return error.EmptyResponse;
        }

        var response_buffer = try self.allocator.alloc(u8, file_size);
        const bytes_read = try file.readAll(response_buffer);

        // Si leímos menos bytes que el tamaño del archivo, ajustar el buffer
        if (bytes_read < file_size) {
            const new_buffer = try self.allocator.dupe(u8, response_buffer[0..bytes_read]);
            self.allocator.free(response_buffer);
            response_buffer = new_buffer;
        }

        // Intentar analizar el JSON para extraer los campos relevantes de la respuesta OpenAI
        var parsed = json.parseFromSlice(json.Value, self.allocator, response_buffer, .{}) catch |err| {
            std.debug.print("Error al analizar JSON: {s}\n", .{@errorName(err)});
            std.debug.print("Respuesta recibida: {s}\n", .{response_buffer});
            return ApiResponse{
                .content = response_buffer,
                .allocator = self.allocator,
            };
        };
        defer parsed.deinit();

        // Extraer el contenido relevante según la estructura de la API de OpenAI
        var response_content: []u8 = undefined;

        // Formato esperado: { "choices": [{ "message": { "content": "texto_respuesta" } }] }
        if (parsed.value.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                if (choices.array.items[0].object.get("message")) |message| {
                    if (message.object.get("content")) |content| {
                        if (content == .string) {
                            response_content = try self.allocator.dupe(u8, content.string);
                            self.allocator.free(response_buffer);
                            return ApiResponse{
                                .content = response_content,
                                .allocator = self.allocator,
                            };
                        }
                    }
                }
            }
        }

        // Si no podemos extraer el contenido usando la estructura OpenAI, intentar otras estructuras
        if (parsed.value.object.get("text")) |text_value| {
            if (text_value == .string) {
                response_content = try self.allocator.dupe(u8, text_value.string);
                self.allocator.free(response_buffer);
            } else {
                response_content = response_buffer;
            }
        } else if (parsed.value.object.get("response")) |response_value| {
            if (response_value == .string) {
                response_content = try self.allocator.dupe(u8, response_value.string);
                self.allocator.free(response_buffer);
            } else {
                response_content = response_buffer;
            }
        } else if (parsed.value.object.get("generated_text")) |generated_text| {
            if (generated_text == .string) {
                response_content = try self.allocator.dupe(u8, generated_text.string);
                self.allocator.free(response_buffer);
            } else {
                response_content = response_buffer;
            }
        } else {
            // Si no encontramos los campos esperados, usar la respuesta completa
            response_content = response_buffer;
        }

        return ApiResponse{
            .content = response_content,
            .allocator = self.allocator,
        };
    }

    // Función auxiliar para extraer términos de búsqueda
    fn extractSearchTerm(text: []const u8) []const u8 {
        const search_terms = [_][]const u8{ "buscar", "encontrar", "localizar", "ubicar" };

        for (search_terms) |term| {
            if (std.mem.indexOf(u8, text, term)) |pos| {
                if (pos + term.len + 1 < text.len) {
                    const rest = text[pos + term.len + 1 ..];
                    // Intentar extraer la primera palabra después del término de búsqueda
                    if (std.mem.indexOf(u8, rest, " ")) |space_pos| {
                        return rest[0..space_pos];
                    } else {
                        return rest;
                    }
                }
            }
        }

        return "archivo"; // Valor por defecto
    }
};

/// Función para probar la comunicación con la API
pub fn testApiConnection(allocator: std.mem.Allocator) !void {
    var client = try ApiClient.init(allocator);
    defer client.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Conectando con la API de Gemini...\n", .{});

    var response = try client.sendPrompt("Hola, ¿cómo estás?");
    defer response.deinit();

    try stdout.print("Respuesta de la API: {s}\n", .{response.content});
}
