---
title: "Demoing FortiAIGate"
linkTitle: "Demoing FortiAIGate"
weight: 300
---

## Demoing the FortiAIGate
In this section we will show how the FortiAIGate enforces, monitors, and protects LLM communications for customers. We will show the process using a three step process:

    * Expose - demonstrate the vulnerability on an unprotected LLM with real attack payloads
    * Configure - apply the FortiAIGate control (AI Guard scanner + action)
    * Validate - confirm the action with the same payload, view logs, and occasionally run a negative test to verify existing operations

Each phase will produce log evidence (`subtype=ai-security`, `action=blocked`) suitable for compliance audits and security posture reporting.

## How it Works
FortiAIGate uses AI Guards to look at the data as it flows from the client to the LLM as well as the response from the LLM to the client. These include the following:

### Input Guards
This is the information that flows from the client application, in our case the chatbot application. These include:
    
* Prompt Injection Detection
* Data Loss Prevention
* Toxicity Filtering
* Custom Rule Filters

### Output Guards
This is the information that flows from the LLM to the client application. These include:

* Data Loss Prevention
* Toxicity Filtering
* Custom Rule Filters

{{< notice info >}}Notice that there is no "Prompt Injection Protection" on the output guard. That is because there is no prompt only a response from the LLM.{{< /notice >}}
