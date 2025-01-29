from openai import OpenAI
import gradio as gr


# Define the predict function
def predict(message, history, temperature, max_tokens, model):

    # Create a client
    client = OpenAI(base_url=f"http://localhost:8000/v1", api_key="test-key")

    history_openai_format = []

    for human, assistant in history:
        history_openai_format.append({"role": "user", "content": human})
        history_openai_format.append(
            {"role": "assistant", "content": assistant})

    history_openai_format.append({"role": "user", "content": message})

    response = client.chat.completions.create(
        model=model,
        messages=history_openai_format,
        temperature=temperature,
        max_tokens=max_tokens,
        stream=True
    )

    partial_message = ""
    for chunk in response:
        if chunk.choices[0].delta.content is not None:
            partial_message = partial_message + chunk.choices[0].delta.content
            yield partial_message


if __name__ == "__main__":
    # Launch the chat interface
    gr.ChatInterface(
        predict,
        title="vLLM Demo Chatbot",
        description="vLLM Demo Chatbot",
        additional_inputs_accordion=gr.Accordion(open=True, label="Settings"),
        additional_inputs=[
            gr.Slider(
                label="Temperature",
                value=0.6,
                minimum=0.0,
                maximum=1.0,
                step=0.05,
                interactive=True,
                info="Higher values produce more diverse outputs",
            ),
            gr.Slider(
                label="Max new tokens",
                value=500,
                minimum=0,
                maximum=4096,
                step=64,
                interactive=True,
                info="The maximum numbers of new tokens",
            ),
            gr.Dropdown(
                choices=[
                    "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B",
                    "deepseek-ai/DeepSeek-R1-Distill-Qwen-32B",
                ],
                interactive=True,
                value="deepseek-ai/DeepSeek-R1-Distill-Qwen-7B",
                label="Model",
            ),
        ]
    ).launch()
