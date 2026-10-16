---
created: 2026-10-14T10:42
updated: 2026-10-14T11:38
tags:
  - zama
  - brain-sync
  - important
---
# Solutions Engineer \- Trial Brief

# Scenario

A tokenized-equities issuer has just signed with Zama. They issue stock tokens backed one-to-one by shares held at a regulated custodian, distribute them through a handful of exchanges, and let holders withdraw to self-custody. Their larger holders have told them they will not put sizable volumes on a public chain where every position is visible. So the issuer wants a confidential version of their tokens.

You are the engineer Zama has put on the account. This is the email their CTO sent after the kick-off call:

> Thanks for the call yesterday. We would love to explore confidential tokenized stocks using Zama, and have this support in our web app, in retail wallets, major custody providers like Fireblocks/Safe and in exchange wallet apps. Our institutional holders keep their tokens with digital-asset custodians, so it has to work there too. It also has to stay tradeable on the CEX/DEXs we're listed on today otherwise we lose the liquidity.  
>   
> The demo you showed for confidential swaps and vaults looked great. Would love to know how we enable this in our tokens as well.  
>   
> Our internal customer service agents need access to the full register at all times, and regulators in different jurisdictions may need to see it on request. We’d also like to understand how our KYT/AML providers would continue doing transaction risk scoring and KYT for us and our partners.  
>   
> We’ll send some docs along on this separately but at a high-level, dividends and stock splits are rebased in some of our tokens; in others we pay on a quarterly basis in USDC. We publish total supply daily against the shares to CMC/CG and need this to continue working.  
>   
> What can we show to our board and when?

# The task

Work out what you would tell this customer, design the integration, and build a thin slice of it.

Your deliverables:

1. **A plan you would show to the customer’s CTO and Product teams**: What would you walk the customer through as a plan to deliver this? Assume you will be showing this to Zama product, engineering, and business teams (at trial presentation on Day 2\) on how to go approach this engagement with the customer’s teams.  
2. **One small slice to demo (Solidity \+ script or minimal app)**: Pick a requirement from the customer brief you think is interesting and build the thinnest version that proves your approach works. Tell us why you picked it over the others.

## Scope and constraints

* **Stay focussed and have a clear plan**: You will likely not be able to cover everything within this trial day challenge given the time constraints. Pick and choose judiciously, and then explain in your presentation why you did so.  
* **Consider the handoff to internal Zama product/engineering teams**: The plan you present to the customer also needs to be actionable by internal Zama teams. Consider whether it has sufficient definition  
* **Use any AI agents and tools you like**: Be ready to talk about how you used them.  
* **Ask questions throughout**: You will meet several of the team over the two days.  
* **Any demo should run on Sepolia**: No special access is needed for Zama testnet.

## Where to start

* [Zama Protocol documentation](https://docs.zama.org/protocol)  
  * How [confidential tokens and wrappers](https://docs.zama.org/protocol/protocol-apps) work  
  * How [confidential vaults/vault batchers](https://docs.zama.org/protocol/confidential-vault) work  
  * How [confidential swaps](https://docs.zama.org/protocol/confidential-swap) work  
* [Zama SDK](https://github.com/zama-ai/sdk) (stable release) and the [Zama SDK documentation](https://docs.zama.org/protocol/sdk)  
  * [Example apps](https://docs.zama.org/protocol/examples), including the confidential token examples  
* For context on the customer side, look at how today's tokenized equity and fund platforms work: issuance, transfer agents, custody, exchange distribution and corporate actions.

# Presenting

You present to the company-wide open-call at 17:00 on Day Two, followed by Q\&A. Most of the audience (Product, Blockchain, research and the business teams) will not have seen this brief.

Please cover:

* A short introduction to yourself and your background.  
* Explain the context of the challenge to people attending, as they will not know the challenge you’ve been given.  
* Walk through your deliverables/demo  
* What you learned about the Protocol / product that you didn’t know before Day 1\.  
* How you used AI on the task, if you did  
* Leave time for Q\&A (during and after your presentation)