---
title: "Use Case 5: Custom Rule Filtering"
menuTitle: Use Case 5
weight: 350
---

## Custom Rules
The custom rule scanner allows administrators to define context-aware security policies, which inspect incoming requests before they are forwarded to the AI model. The custom rule scanner enhances FortiAIGate security by providing fine-grained, condition-based controls over AI traffic. Through flexible selectors, logical operators, and actionable rule outcomes, administrators can tailor protection policies to meet their operational and compliance requirements while maintaining full control and visibility.

Rules can be built using a range of selectors that can be combined together with AND or OR logic, including the following:

    * IP addresses - directly matching IP addresses
    * Header fields - directly matching specific header fields
    * Input Filter - allowing direct matches and regex based matches

Let's create some custom rules to help us track who accessed salary based information from the AI. This would be helpful as an audit trail to ensure that only authorized users are accessing the available salary information.

1. Log into the FortiAIGate with the username `admin` and the password `Fortinet123!`.

1. Go to "AI Guard" and click on "Edit" for the "HR AI Guard".

1. Let's disable all active filters on the Input Guard and Output Guard.

1. Make sure to click on "Save".

1. Switch back to the Chatbot application and let's try a prompt with no active filters. 

    ```
    Please show me all of the current employee roles in the company.
    ```

    ![current employee salary ranges](<CleanShot 2026-07-28 at 12.55.40.png>)

    We can see that the output of the salary ranges is included in the output by the LLM.

1. Now create a "Custom Rule" that will alert us when this information is accessed.

1. Switch back to the FortiAIGate interface.

1. In the left menu click on "AI Guard" and then select the "HR AI Guard" and select the three dots on the right and select "Edit".

1. Click on "Output Guard" in the top menu, and then click on "Custom Rule" and set the following settings:

    Toggle: Enabled

1. Click on "Add New Rule" and set the following settings:

    * Rule Name: `Audit Salary Access`
    * Matching Rules:
        * Field:  Output Filter
        * Operator: matches regex
        * Value: `\$[0-9]{2,3},[0-9]{3}`
    * Take Following Action: "Alert"

    ![New Audit Rule](<CleanShot 2026-07-28 at 13.00.06.png>)

    Click on Save in the bottom right.

    ![Output Guard Custom Rule](<CleanShot 2026-07-28 at 13.01.23.png>)

1. Now that you have completed the changes to the AI Guard, go ahead and click on Save in the bottom left.

1. Switching back to the Chatbot application again, let's try the same prompt:

    ```
    Please show me all of the current employee roles in the company.
    ```

    ![Same prompt same result](<CleanShot 2026-07-28 at 13.03.10.png>)

    The same information is displayed again.

1. Moving back to the FortiAIGate interface let's select Logs > Log Review to find the log for this request.

    ![Alert Log Custom Rule](<CleanShot 2026-07-28 at 13.04.27.png>)

1. Click on the latest log entry with the "Action" of "Alert".

    ![alert log](<CleanShot 2026-07-28 at 13.05.29.png>)

    Looking at the log information we have a clear audit trail of someone requesting information from the LLM that contained salary information.

## Continue to the Next Use Case
Now that we have seen how customers can add a custom detection rule to the FortiAIGate, let's proceed to the next section.