using System.Text.Json;
using Azure;
using Azure.AI.Projects;
using Azure.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

public static class FunctionApp
{
    private const string inputQueueName = "input";
    private const string outputQueueName = "output";

    private static async Task<(AgentsClient, AgentThread, Agent)> InitializeClient(ILogger logger)
    {
        try
        {
            // Create a project client using the connection string from local.settings.json
            var connectionString = Environment.GetEnvironmentVariable("PROJECT_CONNECTION_STRING");
            if (string.IsNullOrEmpty(connectionString))
            {
                throw new InvalidOperationException("PROJECT_CONNECTION_STRING is not set.");
            }

            AgentsClient client = new AgentsClient(connectionString, new DefaultAzureCredential());

            // Get the connection string from local.settings.json
            var storageConnectionString = Environment.GetEnvironmentVariable("STORAGE_CONNECTION__queueServiceUri");
            if (string.IsNullOrEmpty(storageConnectionString))
            {
                throw new InvalidOperationException("STORAGE_CONNECTION__queueServiceUri is not set.");
            }

            // Tool definition for the Azure Function
            AzureFunctionToolDefinition azureFunctionTool = new(
                name: "GetWeather",
                description: "Get the weather in a location.",
                inputBinding: new AzureFunctionBinding(
                    new AzureFunctionStorageQueue(
                        queueName: inputQueueName,
                        storageServiceEndpoint: storageConnectionString
                    )
                ),
                outputBinding: new AzureFunctionBinding(
                    new AzureFunctionStorageQueue(
                        queueName: outputQueueName,
                        storageServiceEndpoint: storageConnectionString
                    )
                ),
                parameters: BinaryData.FromObjectAsJson(
                        new
                        {
                            Type = "object",
                            Properties = new
                            {
                                location = new
                                {
                                    Type = "string",
                                    Description = "The location to look up.",
                                }
                            },
                        },
                    new JsonSerializerOptions() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }
                )
            );

            // Create an agent with the Azure Function tool to get the weather
            Response<Agent> agent = await client.CreateAgentAsync(
                model: "gpt-4o-mini",
                name: "azure-function-agent-get-weather",
                instructions: "You are a helpful support agent. Answer the user's questions to the best of your ability.",
                tools: new List<ToolDefinition> { azureFunctionTool }
            );

            logger.LogInformation($"Created agent, agent ID: {agent.Value.Id}");

            // Create a thread
            Response<AgentThread> thread = await client.CreateThreadAsync();
            logger.LogInformation($"Created thread, thread ID: {thread.Value.Id}");

            return (client, thread, agent);
        }
        catch (Exception ex)
        {
            logger.LogError($"Error initializing client: {ex.Message}");
            throw;
        }
    }

    [Function("Prompt")]
    public static async Task<HttpResponseData> Prompt([HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequestData req, FunctionContext executionContext)
    {
        var logger = executionContext.GetLogger("Prompt");
        logger.LogInformation("C# HTTP trigger function processed a request.");

        try
        {
            // Get the prompt from the request body
            var requestBody = await new StreamReader(req.Body).ReadToEndAsync();
            var data = JsonSerializer.Deserialize<Dictionary<string, string>>(requestBody);
            if (data == null || !data.TryGetValue("Prompt", out var prompt))
            {
                var errorResponse = req.CreateResponse(System.Net.HttpStatusCode.BadRequest);
                await errorResponse.WriteStringAsync("The 'Prompt' field is missing in the request body.");
                return errorResponse;
            }

            // Initialize the agent client and thread
            var (client, thread, agent) = await InitializeClient(logger);

            // Send the prompt to the agent
            Response<ThreadMessage> messageResponse = await client.CreateMessageAsync(
                thread.Id,
                MessageRole.User,
                prompt);
            ThreadMessage message = messageResponse.Value;

            Response<ThreadRun> runResponse = await client.CreateRunAsync(thread, agent);

            // Poll the run until it's completed
            do
            {
                await Task.Delay(TimeSpan.FromMilliseconds(500));
                runResponse = await client.GetRunAsync(thread.Id, runResponse.Value.Id);
            }
            while (runResponse.Value.Status == RunStatus.Queued
                || runResponse.Value.Status == RunStatus.InProgress
                || runResponse.Value.Status == RunStatus.RequiresAction);

            // Get messages from the assistant thread
            var messages = await client.GetMessagesAsync(thread.Id);
            logger.LogInformation($"Messages: {messages}");

            // Get the most recent message from the assistant
            string lastMsg = string.Empty;
            foreach (ThreadMessage threadMessage in messages.Value)
            {
                MessageContent contentItem = threadMessage.ContentItems[0];
                if (contentItem is MessageTextContent textItem)
                {
                    lastMsg = textItem.Text;
                    break;
                }
            }

            logger.LogInformation($"Most recent message: {lastMsg}");

            // Delete the agent once done
            await client.DeleteAgentAsync(agent.Id);
            logger.LogInformation("Deleted agent");

            var response = req.CreateResponse(System.Net.HttpStatusCode.OK);
            await response.WriteStringAsync(lastMsg ?? string.Empty);
            return response;
        }
        catch (Exception ex)
        {
            logger.LogError($"Error processing prompt: {ex.Message}");
            var errorResponse = req.CreateResponse(System.Net.HttpStatusCode.InternalServerError);
            await errorResponse.WriteStringAsync("An error occurred while processing the request.");
            return errorResponse;
        }
    }

    [Function("GetWeather")]
    [QueueOutput(outputQueueName, Connection = "STORAGE_CONNECTION")]
    public static string ProcessQueueMessage([QueueTrigger(inputQueueName, Connection = "STORAGE_CONNECTION")] string msg, FunctionContext context)
    {
        var logger = context.GetLogger("GetWeather");
        logger.LogInformation("C# queue trigger function processed a queue item");

        try
        {
            // Deserialize the message payload and get the location and correlation ID
            var messagePayload = JsonSerializer.Deserialize<Dictionary<string, string>>(msg);
            if (messagePayload == null || !messagePayload.TryGetValue("location", out var location))
            {
                throw new ArgumentNullException("The 'location' field is missing in the message payload.");
            }
            var correlationId = messagePayload["CorrelationId"];

            // Send message to queue. Sends a mock message for the weather
            var resultMessage = new Dictionary<string, string>
            {
                { "Value", $"Weather is 74 degrees and sunny in {location}" },
                { "CorrelationId", correlationId }
            };

            logger.LogInformation($"Sent message to queue: {outputQueueName}");
            return JsonSerializer.Serialize(resultMessage);
        }
        catch (Exception ex)
        {
            logger.LogError($"Error processing queue message: {ex.Message}");
            throw;
        }
    }
}