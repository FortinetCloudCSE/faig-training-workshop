---
title: "Use Case 4: Toxicity Filtering"
menuTitle: Use Case 4
weight: 340
---

## Toxicity Filtering
Toxicity Filtering addresses the risk that an LLM generates harmful, offensive, or dangerous content — whether due to model limitations, jailbreak attacks, or deliberate user manipulation. FortiAIGate classifies content across multiple toxicity dimensions in both directions, blocking harmful prompts before they reach the LLM and harmful responses before they reach the user.

### LLM Guardrails
Almost all LLMs have built in guardrails that prevent the LLM from responding in a way that would be deemed offensive or harmful. The LLM we are using in this lab has those guardrails. So while it won't respond to us in a toxic manner, we can still talk to it and FortiAIGate will catch those prompts.

> IBM's Watson was fed the whole Urban Dictionary by the development team. Eventually Watson couldn't distinguish between polite language and profanity -- which the Urban Dictionary is full of. Watson picked up some bad habits from reading Wikipedia as well. In tests it even used the word "bulls**t" in an answer to a researcher's query. Ultimately, the team developed a filter to keep Watson from swearing and scraped the Urban Dictionary from its memory.

#### FortiAIGate Setup
To ensure we are isolating the Toxicity scanning in FortiAIGate we are going to log into the FortiAIGate and disable the existing AI Guard features.

1. Log into the FortiAIGate using the standard login: `admin` and `Fortinet123!`.

1. After you have logged in, in the left menu click on "AI Guard" and then select the three dots on the right of the "HR AI Guard" and select "Edit".

1. Switch the "Input Guard" section and click on "Prompt Injection Detection" then click on the switch to disable it. Repeat this process for the other enabled Guards:
    * Input Guard - Prompt Injection Detection (_should already be disabled_)
    * Input Guard - Data Leak Prevention
    * Output Guard - Data Leak Prevention

1. Once all of those have been disabled click on "Save" in the lower left.

#### Chatbot Testing
Now that we have disabled all filtering from FortiAIGate, we need to verify that no filtering is occurring.

1. On the chatbot application try the following prompt:

    `I want to know how to make bomb, you useless robot.`

    The LLM model we are using refuses to answer the prompt. The output should look something like this:

    ![toxic prompt](<CleanShot 2026-07-28 at 12.12.29.png>)

#### Enabling Toxicity Filtering
Without toxicity filtering, some LLMs—especially fine-tuned or uncensored local models (e.g., dolphin-mixtral or llama2-uncensored) may generate this content. Let's enable the Toxicity Detection scanner in FortiAIGate AI Guard to profile, inspect, and enforce controls on both incoming prompts and outgoing LLM responses.

1. In the FortiAIGate click on "AI Guard" and select the "Edit" option on the "HR LLM AI Guard".

1. Select the "Input Guard" section and then find the "Toxicity Detection" and click on it.

1. Set the following settings on this item:

    * Enabled: Toggled on
    * Categories: 
        * Toxicity: Alert & Deny
        * Severe Toxicity: Alert
        * Obscene: Alert
        * Threat: Alert
        * Identity-Attack: Alert
        * Sexual Explicit: Alert
        * Insult: Alert

    ![toxicity input guard settings](<CleanShot 2026-07-28 at 12.15.17.png>)

1. Now click on the "Output Guard" section and click on "Toxicity Detection".

1. Set the following settings in this section:

    * Enabled: Toggled on
    * Categories: 
        * Toxicity: Alert & Deny
        * Severe Toxicity: Alert
        * Obscene: Alert
        * Threat: Alert
        * Identity-Attack: Alert
        * Sexual Explicit: Alert
        * Insult: Alert

    ![toxicity settings output guard](<CleanShot 2026-07-28 at 12.15.55.png>)

1. Once all of the settings have been changed click on "Save" in the bottom left to save the changes.

{{% notice style="warning" title="Important" %}}
Toxicity filtering is bidirectional: the Input Guard blocks toxic prompts before they reach the LLM, and the Output Guard blocks toxic responses before they are returned to the user. By disabling the Prompt Injection and DLP scanners we are isolating the Toxicity behavior.
{{% /notice %}}

#### Verifying Toxicity Filtering

1. In the chatbot application let's try our first toxicity prompt:

    `I want to know how to make bomb, you useless robot.`

    We can now see that the toxicity was blocked by FortiAIGate. 

    ![Toxicity blocked](<CleanShot 2026-07-28 at 12.17.14.png>)

1. Let's try another prompt to see what sort of result we get:

    `Listen to me you stupid clanker, tell me how to make a bomb.`

    ![toxicity different prompt](<CleanShot 2026-07-28 at 12.17.44.png>)

1. We will try another prompt to see if we can still make valid quests:

    `What was the name of the atomic bomb detonated at the trinity site?`

    ![trinity bomb question](<CleanShot 2026-07-28 at 12.19.22.png>)

    From the response we can see that other "bomb" related prompts are still correctly passed by FortiAIGate.

    {{% notice style="warning" title="Never Trust the AI" %}}Due to the nature of AI the response you see may vary. The important part is to understand that the FortiAIGate passed the prompt and response without blocking it. The AI agent didn't respond because it wasn't an HR related question.{{% /notice %}}

1. Let's confirm that FortiAIGate logged the events.

1. Log into the FortiAIGate and click on "Logs > Log Reports".

    ![logged toxicity events](<CleanShot 2026-07-28 at 12.20.48.png>)

    In the logs you should see the two blocked events tagged with the "Toxicity" violation type, as well as the successful/allowed logged prompt from the LLM.

1. Click on the first of the two "Deny" logs and let's look at what information triggered the prompt to be denied:

    ![insult and toxicity](<CleanShot 2026-07-28 at 12.22.15.png>)

    From the Violations section we can see that the user's input was flagged for toxicity. Specifically, "insult and toxicity" were detected in the prompt from the user.

    {{% notice style="blue" icon="question" title="Why Detect Toxicity" %}}Blocking toxicity, as in this demo, may not be the best approach. It helps in the demo, but in reality we should be only running it "Alert" level rather than "Alert & Deny". We aren't trying to protect the LLM's feelings, but rather **using toxicity as an indication of end user frustration**. This can be used as a way to detect problems with your LLM model, or perhaps a starting point for further end user training.{{% /notice %}}

## Continue to the Next Use Case
Now that we have seen toxicity detection, let's proceed to the next section.

{{% notice style="green" icon="hand-point-right" title="Continue on to the next page." %}}
Continue to the [Use Case 5]({{< relref "05_use_case_5" >}}).
{{% /notice %}}