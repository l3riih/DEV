Agente ia, para terminal, este agente apoyado por un llm, se encragara de realizar tareas que se pasaran por lenguaje natural(realizables desde la tterminal), dependiendo de la compledidad trzara un plan y lo seguira, si la tarea es muy sencilla no. Estose realizara con zig

API:
GET https://text.pollinations.ai/models
Text-To-Text (GET) 🗣️

GET https://text.pollinations.ai/{prompt}

prompt 	Yes 	Text prompt for the AI. Should be URL-encoded. 		
model 	No 	Model for generation. See Available Text Models. 	openai, mistral, etc. 	openai
seed 	No 	Seed for reproducible results. 		
json 	No 	Set to true to receive the response formatted as a JSON string. 	true / false 	false
system 	No 	System prompt to guide AI behavior. Should be URL-encoded. 		
stream 	No 	Set to true for streaming responses via Server-Sent Events (SSE). Handle data: chunks. 	true / false 	false
private 	No 	Set to true to prevent the response from appearing in the public feed. 	true / false 	false
referrer 	No* 	Referrer URL/Identifier. See Referrer Section. 	

Common Body Parameters:
Parameter 	Description 	Notes
messages 	An array of message objects (role: system, user, assistant). Used for Chat, Vision, STT. 	Required for most tasks.
model 	The model identifier. See Available Text Models. 	Required. e.g., openai (Chat/Vision), openai-large (Vision), claude-hybridspace (Vision), openai-audio (STT).
seed 	Seed for reproducible results (Text Generation). 	Optional.
stream 	If true, sends partial message deltas using SSE (Text Generation). Process chunks as per OpenAI streaming docs. 	Optional, default false.
jsonMode / response_format 	Set response_format={ "type": "json_object" } to constrain text output to valid JSON. jsonMode: true is a legacy alias. 	Optional. Check model compatibility.
tools 	A list of tools (functions) the model may call (Text Generation). See OpenAI Function Calling Guide. 	Optional.
tool_choice 	Controls how the model uses tools. 	Optional.
private 	Set to true to prevent the response from appearing in the public feed. 	Optional, default false.
reasoning_effort 	Sets reasoning effort for o3-mini model (Text Generation). 	Optional. Options: low, medium, high.

El modelor sera: gemini