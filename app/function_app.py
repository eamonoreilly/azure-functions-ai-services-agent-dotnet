import azure.functions as func
import json
import logging
import os
import time
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.storage.queue import QueueClient, BinaryBase64EncodePolicy, BinaryBase64DecodePolicy

app = func.FunctionApp()


# Name of the queues to get and send the function call messages
input_queue_name = "input"
output_queue_name = "output"

# Function to initialize the agent client and the tools Azure Functions that the agent can use
def initialize_client():
    # Create a project client using the connection string from local.settings.json
    project_client = AIProjectClient.from_connection_string(
        credential=DefaultAzureCredential(),
        conn_str=os.environ["PROJECT_CONNECTION_STRING"]
    )

    # Get the connection string from local.settings.json
    storage_connection_string = os.environ["STORAGE_CONNECTION__queueServiceUri"]

    # Create an agent with the Azure Function tool to get the weather
    agent = project_client.agents.create_agent(
        model="gpt-4o-mini",
        name="azure-function-agent-get-weather",
        instructions="You are a helpful support agent. Answer the user's questions to the best of your ability.",
        headers={"x-ms-enable-preview": "true"},
        tools=[
            {
                "type": "azure_function",
                "azure_function": {
                    "function": {
                        "name": "GetWeather",
                        "description": "Get the weather in a location.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "location": {"type": "string", "description": "The location to look up."}
                            },
                            "required": ["location"]
                        }
                    },
                    "input_binding": {
                        "type": "storage_queue",
                        "storage_queue": {
                            "queue_service_uri": storage_connection_string,
                            "queue_name": input_queue_name
                        }
                    },
                    "output_binding": {
                        "type": "storage_queue",
                        "storage_queue": {
                            "queue_service_uri": storage_connection_string,
                            "queue_name": output_queue_name
                        }
                    }
                }
            }
        ],
    )
    logging.info(f"Created agent, agent ID: {agent.id}")

    # Create a thread
    thread = project_client.agents.create_thread()
    logging.info(f"Created thread, thread ID: {thread.id}")

    return project_client, thread, agent

@app.route(route="prompt", auth_level=func.AuthLevel.FUNCTION)
def prompt(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Python HTTP trigger function processed a request.')

    # Get the prompt from the request body
    req_body = req.get_json()
    prompt = req_body.get('Prompt')

    # Initialize the agent client
    project_client, thread, agent = initialize_client()

    # Send the prompt to the agent
    message = project_client.agents.create_message(
        thread_id=thread.id,
        role="user",
        content=prompt,
    )
    logging.info(f"Created message, message ID: {message.id}")

    # Run the agent
    run = project_client.agents.create_run(thread_id=thread.id, assistant_id=agent.id)
    # Monitor and process the run status
    while run.status in ["queued", "in_progress", "requires_action"]:
        time.sleep(1)
        run = project_client.agents.get_run(thread_id=thread.id, run_id=run.id)

        if run.status not in ["queued", "in_progress", "requires_action"]:
            break

    logging.info(f"Run finished with status: {run.status}")

    if run.status == "failed":
        logging.error(f"Run failed: {run.last_error}")

    # Get messages from the assistant thread
    messages = project_client.agents.get_messages(thread_id=thread.id)
    logging.info(f"Messages: {messages}")

    # Get the last message from the assistant
    last_msg = messages.get_last_text_message_by_sender("assistant")
    if last_msg:
        logging.info(f"Last Message: {last_msg.text.value}")

    # Delete the agent once done
    project_client.agents.delete_agent(agent.id)
    print("Deleted agent")

    return func.HttpResponse(last_msg.text.value)

# Function to get the weather
@app.function_name(name="GetWeather")
@app.queue_trigger(arg_name="msg", queue_name="input", connection="STORAGE_CONNECTION")  
def process_queue_message(msg: func.QueueMessage) -> None:
    logging.info('Python queue trigger function processed a queue item')

    # Queue to send message to
    queue_client = QueueClient(
        os.environ["STORAGE_CONNECTION__queueServiceUri"],
        queue_name="output",
        credential=DefaultAzureCredential(),
        message_encode_policy=BinaryBase64EncodePolicy(),
        message_decode_policy=BinaryBase64DecodePolicy()
    )

    messagepayload = json.loads(msg.get_body().decode('utf-8'))
    location = messagepayload['location']
    correlation_id = messagepayload['CorrelationId']

    # Send message to queue. Sends a mock message for the weather
    result_message = {
        'Value': 'Weather is 74 degrees and sunny in ' + location,
        'CorrelationId': correlation_id
    }
    queue_client.send_message(json.dumps(result_message).encode('utf-8'))

    logging.info(f"Sent message to queue: {input_queue_name} with message {result_message}")
