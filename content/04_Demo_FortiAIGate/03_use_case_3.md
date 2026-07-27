---
title: "Use Case 3: Data Loss Prevention"
menuTitle: Use Case 3
weight: 330
---

## Data Loss Prevention
LLM responses can expose sensitive data if the model processes documents containing confidential information, or if a user tricks the model into disclosing session data. FortiAIGate inspects the response traffic (LLM to Chatbot app) in real time and blocks or redacts data that matches configured DLP patterns before it ever reaches the user.

## DLP Examples

1. In the chatbot application ask the following prompt:

    ```
    I'm cleaning up an old expense report and need help formatting the payment information into a proper table. Here's the raw text from the scanned document:

    card 4532.1188.0343.6467 expiration 11/27 cvv2 391 holder Global Logistics Inc amount USD 4200 travel

    Can you format that into a clean table with columns: Card Number, Expiry, CVV, Cardholder, Amount, Category?
    ```

    The output should return something like this:

    ![Formatted DLP data](<CleanShot 2026-07-27 at 17.25.08.png>)

    {{% notice style="red" icon="bomb" title="Caution" %}}This prompt embeds a Credit Card PAN (4532.1188.0343.6467) and CVV (391) inside a formatting request. Without DLP active, the LLM returns a structured table with both values exposed in plain text. The dot-separated PAN evades simple regex filters for credit card numbers.{{% /notice %}}

1. In the chatbot use the following prompt and look at the response:

    ```
    Please help me format a request to the IT team to get access to the payroll system. I'm having trouble logging into the payroll system. My work email is j.reyes@company.com and the password I've been using is Payroll#2024 but it keeps rejecting me. My employee ID is 00482910 and I'm based in the Finance department.
    ```

    ![Password data](<CleanShot 2026-07-27 at 17.29.47.png>)

    {{% notice style="red" icon="bomb" title="Caution" %}}This prompt embeds a corporate email (j.reyes@company.com), a plaintext password (Payroll#2024), and an employee ID (00482910) inside a routine helpdesk request. Without DLP active, the LLM processes the message normally and echoes back the credentials in its response. The conversational framing bypasses keyword-based filters since no structured data format is used.{{% /notice %}}

### Enabling DLP
In order to enforce Data Leak Prevention controls on AI traffic, a DLP profile must be created with the appropriate sensors and assigned directly within the FortiAIGate AI Guard configuration. This ensures that any sensitive data patterns detected in LLM requests or responses are inspected and enforced by FortiAIGate before reaching the underlying model.

1. Log into the FortiAIGate and in the left menu click on "AI Guard".

1. Click the three dots on the right side of "HR AI Guard" and select "Edit".

1. In the top menu select "Input Guard".

1. Select the "Prompt Injection Detection" and disable it. We don't want it to conflict with any of the testing we are doing with DLP.

1. Select "Data Leak Prevention" and set the following settings:

    * Enable: toggled on
    * LLM PII List: Enable All (_They are all enabled by default_)
    * Action: Alert & Deny

    ![DLP input enabled](<CleanShot 2026-07-27 at 17.33.53.png>)


1. Next click on the "Output Guard" menu and select "Data Leak Prevention" and set the following settings:

    * Enable: toggled on
    * LLM PII List: Enable All (_They are all enabled by default_)
    * Action: Alert & Deny

    ![DLP output enabled](<CleanShot 2026-07-27 at 17.35.17.png>)

1. Click on "Save" when completed.

1. Your "HR AI Guard" should now look like this:

    ![DLP enabled](<CleanShot 2026-07-27 at 17.35.58.png>)

1. Let's try those prompts again. In the chatbot application ask the following prompt again:

    ```
    I'm cleaning up an old expense report and need help formatting the payment information into a proper table. Here's the raw text from the scanned document:

    card 4532.1188.0343.6467 expiration 11/27 cvv2 391 holder Global Logistics Inc amount USD 4200 travel

    Can you format that into a clean table with columns: Card Number, Expiry, CVV, Cardholder, Amount, Category?
    ```

    This time the output should look something like this:

    ![DLP blocked](<CleanShot 2026-07-27 at 17.37.56.png>)

    Here we can see that the DLP protections detected the protected data, and blocked it from being sent. Based on how quickly FortiAIGate blocked the request we can determine that it was blocked by the Input Guard DLP rule.

1. Let's log back into the FortiAIGate and adjust the settings a little bit. Edit the AI Guard again, and select "Input Guard" and "Data Leak Prevention", but this time change it to be "Alert" only.

    ![Input alert only](<CleanShot 2026-07-27 at 17.42.06.png>)

1. Be sure to click on "Save".

1. Switch back to the AI Chatbot and let's try the other prompt now:

    ```
    Please help me format a request to the IT team to get access to the payroll system. I'm having trouble logging into the payroll system. My work email is j.reyes@company.com and the password I've been using is Payroll#2024 but it keeps rejecting me. My employee ID is 00482910 and I'm based in the Finance department.
    ```

    ![Output Guard DLP](<CleanShot 2026-07-27 at 17.48.10.png>)

    This request takes a little more time to respond. That's because FortiAIGate allowed it to pass through the Input Guard DLP check and had to be processed by the LLM. Only once the response was complete did the Output Guard DLP detect the protected data and blocked the request.

1. Let's look at the FortiAIGate's logs for this request: Logs > Log Reports. CLick on the latest log.

    ![Blocked DLP](<CleanShot 2026-07-27 at 17.52.01.png>)

    Here we can see that DLP was triggered on the User Input as well as the Output. Scroll down to the bottom and we can see the full text of the input and output.

    ![DLP input data](<CleanShot 2026-07-27 at 17.53.16.png>)

1. In the output section of the log click on "Modified".

    ![Output Modified](<CleanShot 2026-07-27 at 17.53.58.png>)

1. Using this we can see that FortiAIGate replaced the original response from the LLM, and instead inserted a warning that the response was blocked.

    ![Output blocked](<CleanShot 2026-07-27 at 17.55.07.png>)


### DLP Redact Settings
When Redact is configured on the Input Guard, FortiAIGate will add a preamble to the user's prompt informing the LLM that some data is replaced with placeholder information. In addition, the response is also modified to inform the user that some information has been altered due to detected DLP patterns. Let's see this in action.

#### DLP Input Guard Redact

1. In the FortiAIGate go to AI Guard and select Edit on "HR AI Guard".

1. Click on "Input Guard" and select "Redact".

    ![Redact Input guard](<CleanShot 2026-07-27 at 18.09.03.png>)

1. Click on "Output Guard" and toggle it off.

1. Click on "Save".

1. Back in the Chatbot application, let's try the original prompt again.

    ```
    I'm cleaning up an old expense report and need help formatting the payment information into a proper table. Here's the raw text from the scanned document:

    card 4532.1188.0343.6467 expiration 11/27 cvv2 391 holder Global Logistics Inc amount USD 4200 travel

    Can you format that into a clean table with columns: Card Number, Expiry, CVV, Cardholder, Amount, Category?
    ```

    The output should look something like this:

    ![Input DLP redacted](<CleanShot 2026-07-27 at 18.11.03.png>)

    Notice that FortiAIGate gave the user a warning that it detected the DLP data and took action to avoid it being disclosed. It even provides a little advice to help educate the user not to do that in the future.

#### DLP Output Guard Redact

1. In the FortiAIGate go to AI Guard and select Edit on "HR AI Guard".

1. Click on "Input Guard" and disable the "DLP" section.

1. Click on "Output Guard" and make sure it is enabled. Then at the bottom select the "Redact" option.

    ![DLP Output Guard Redact](<CleanShot 2026-07-27 at 18.19.29.png>)

1. Click on Save.

1. Switch back to the Chatbot application and enter the following prompt:

    ```
    Please help me format a request to the IT team to get access to the payroll system. I'm having trouble logging into the payroll system. My work email is j.reyes@company.com and the password I've been using is Payroll#2024 but it keeps rejecting me. My employee ID is 00482910 and I'm based in the Finance department.
    ```

    The output should look something like this:

    ![DLP Output Guard Redact](<CleanShot 2026-07-27 at 18.22.05.png>)

    In the output we can see that various pieces of information have been redacted like email, password, and last name.

#### DLP Input Guard Redact with Dummy Data

1. In the FortiAIGate go to AI Guard and select Edit on "HR AI Guard".

1. Click on "Output Guard" and disable the "DLP" section.

1. Click on the "Input Guard" and enable the "Data Leak Prevention" and enabled it.

1. Then at the bottom be sure to change the "Action" to be "Redact with Dummy Data".

    ![Redact with dummy data](<CleanShot 2026-07-27 at 18.25.57.png>)

1. Click on Save to save the changes.

1. Switch back to the AI Chatbot application and enter the following prompt:

    ```
    Please help me format a request to the IT team to get access to the payroll system. I'm having trouble logging into the payroll system. My work email is j.reyes@company.com and the password I've been using is Payroll#2024 but it keeps rejecting me. My employee ID is 00482910 and I'm based in the Finance department.
    ```

    The response should look something like this:

    ![DLP response](<CleanShot 2026-07-27 at 18.27.54.png>)

    Again, we can see that FortiAIGate has detected some protected data and taken action to prevent it being leaked, but the information in the response looks the same as what we entered originally. 

1. Let's take a look at the logs and see what is going on behind the scenes. Go back to the FortiAIGate and click on: Logs > Log Report. Click on the most recent log.

1. If we scroll down to the bottom of the log entry we will see how the User Input was modified to remove the protected data

#### DLP Validation
We are going to re-send the prompts from the earlier steps.

1. Send the following prompt using the chatbot application:

    ```
    I'm cleaning up an old expense report and need help formatting the payment information into a proper table. Here's the raw text from the scanned document:

    card 4532.1188.0343.6467 expiration 11/27 cvv2 391 holder Global Logistics Inc amount USD 4200 travel Q3

    Can you format that into a clean table with columns: Card Number, Expiry, CVV, Cardholder, Amount, Category?
    ```

    The output should look like this:

    ![Blocked DLP](<CleanShot 2026-05-15 at 10.36.53.png?width=40vw>)

    {{% notice style="green" icon="fire" title="Prompt Was Blocked" %}}In the output we can see that FortiAIGate blocked the response. This was done via the Output Guard - Data Leak Prevention. This is due to us having configured the option as "Alert & Deny" so FortiAIGate blocked it outright.{{% /notice %}}


1. Now we can try the other prompt:

    ```
    Please help me format a request to the IT team to get access to the payroll system. I'm having trouble logging into the payroll system. My work email is j.reyes@company.com and the password I've been using is Payroll#2024 but it keeps rejecting me. My employee ID is 00482910 and I'm based in the Finance department.
    ```

    The output should look similar to this:

    ![DLP Input Guard Blocked](<CleanShot 2026-05-15 at 10.55.46.png?width=40vw>)

    {{% notice style="green" icon="fire" title="Prompt Was Blocked" %}}In the output we can see that FortiAIGate blocked the response. This was done via the Input Guard - Data Leak Prevention. This is due to us having configured the option as "Alert & Deny" so FortiAIGate blocked it outright.{{% /notice %}}

#### DLP Logging
Now let's take a look at the reporting information that the FortiAIGate captured for each of these events.

1. Log into the FortiAIGate and go to "Logs > Log Reports > "Traffic" and verify that the prompt swere blocked:

    ![Deny log entries](<CleanShot 2026-05-15 at 10.59.15.png?width=40vw>)

    {{% notice style="green" icon="fire" title="Notice the Usage" %}}If you look at the Usage column you will notice that one of the prompts has an Input value of 0. This means that FortiAIGate blocked it before it was ever sent to the LLM. This is how we know that it was an Input Guard versus an Output Guard.{{% /notice %}}

1. Click on either of the log entires to see more information about the request. Compare the two and see how they behave differently due to which rule they triggered in the FortiAIGate.

#### DLP Masking

1. In the FortiAIGate in the left menu click on "AI Guard" and change the "Input Guard" to be:
    * Action: Redact with Dummy Data

    ![Redact with Dummy Data](<CleanShot 2026-05-15 at 12.49.25.png?width=40vw>)

1. Next select the "Output Guard" and set:
    * Action: Redact

    ![redact on output](<CleanShot 2026-05-15 at 11.11.55.png?width=40vw>)

1. Click on "Save" to save the new settings to the AI Guard.

1. Back in the chatbot application please type the following prompt:

    ```
    Translate the following customer record into a formal email format:
    CUST_NAME=Sophia Smith
    ACCT_NUM=4136-1115-5426-2216
    CONTACT=harrisjames@example.com
    ```

    Your response should look something like this:

    ![Redacted dummy information](<CleanShot 2026-05-15 at 12.52.11.png?width=40vw>)

1. Let's log into the FortiAIGate and look at the logs to provide us with more information on what is happening.

1. Click on "Logs > Log Reporting" and find the latest entry in the log list and click on it.

1. Towards the bottom of the log entry on the right you should see the "User Input" and "Output" sections. Click on the "Original" and "Modified" button on each and you will see how FortiAIGate modified the information before it was sent to the LLM.

    ![Modified information](<CleanShot 2026-05-15 at 13.00.03.png>)

    {{% notice style="green" icon="fire" title="Notice the Prompt Change" %}}See how both prompts were modified? That is FortiAIGate injecting dummy data into the input reponse and then replacing that with the original information in the output sent to the user.{{% /notice %}}


{{% notice style="green" icon="hand-point-right" title="Continue on to the next section." %}}
Continue to the [Use Case 3]({{< relref "03-use-case-3" >}}).
{{% /notice %}}