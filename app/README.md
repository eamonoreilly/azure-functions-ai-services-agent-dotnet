# Azure AI Agents function calling with Azure Functions

Azure AI Agents supports function calling, which allows you to describe the structure of functions to an Assistant and then return the functions that need to be called along with their arguments. This example shows how to use Azure Functions to process the function calls through queue messages in Azure Storage. You can see a complete working sample on https://github.com/Azure-Samples/azure-functions-ai-services-agent-dotnet

### Supported models

To use all features of function calling including parallel functions, you need to use a model that was released after November 6, 2023.


## Define a function for your agent to call

Start by defining an Azure Function queue trigger function that will process function calls from the queue. 

```C#
// Function to get the weather from an Azure Storage queue where the AI Agent will send function call information
// It returns the mock weather to an output queue with the correlation id for the AI Agent service to pick up the result of the function call
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
```

---

## Create an AI project client and agent

In the sample below we create a client and an agent that has the tools definition for the Azure Function

```C#
// Initialize the client and create agent for the tools Azure Functions that the agent can use
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
```

---

## Create a run and check the output

```C#
// Initialize the agent client and thread
var (client, thread, agent) = await InitializeClient(logger);

// Send the prompt to the agent
Response<ThreadMessage> messageResponse = await client.CreateMessageAsync(
    thread.Id,
    MessageRole.User,
    "What is the weather in Seattle?");
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
```

---

### Get the result of the run and print out

```C#
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
```
