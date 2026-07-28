# Getting help, and giving feedback

Cluster administrators are a small team supporting a large number of users, most of whom
report problems badly. A well-formed report is answered quickly; a vague one costs
several round trips before anyone can even reproduce it. This page is about being the
first kind of user.

## Find the channels before you need them

Every site publishes these somewhere. Find them now, while nothing is broken, and record
them in [templates/site-notes.md](../templates/site-notes.md):

| Channel | Typically used for | Notes |
|---|---|---|
| **Ticket system** (helpdesk, Jira, RT, email-to-ticket) | anything that needs tracking: failures, quota and allocation requests, software installation, account problems | the default. A ticket has a number, a history, and does not get lost |
| **Mailing list / user forum** | questions other users can answer, announcements | search it first; your question has often been asked |
| **Chat** (Slack, Mattermost, Matrix) | quick clarifications, "is the filesystem slow for anyone else?" | fast but ephemeral — anything that needs a fix still belongs in a ticket |
| **Office hours / user meetings** | design questions, scaling plans, anything conversational | the best place for "what is the right way to do this?" |
| **Status page / maintenance calendar** | is it me, or is it the machine? | check this *before* reporting an outage |
| **Direct email to an admin** | almost nothing | it bypasses tracking and lands on one person, who may be on leave |

Rule of thumb: **if it needs an action, it needs a ticket.** Chat is for things that need
an answer.

## What to include in a report

Everything below fits in a short message and removes most of the back-and-forth:

- **What you ran** — the submission command and the job script, or a path to them.
- **The job id.** Alone it lets an administrator see resources, node, exit code and
  timing. Without it, they are guessing.
- **When**, with a timezone. "This morning" is not a timestamp.
- **The actual error** — the tail of the `.err` file, as text, not a screenshot.
- **What you expected instead.**
- **What you already tried**, and what changed. "It worked on Tuesday" is a strong clue.
- **Whether it is reproducible**, and the smallest case that still fails.

```bash
hpc-session fetch <jobid> ./results     # the .out and .err files to quote from
hpc-session run -- sacct -j <jobid> --format=JobID,State,ExitCode,Elapsed,MaxRSS,NodeList
```

Say plainly how it affects you — a blocked deadline is legitimate context. Do not mark
everything urgent; the word stops working, and the person reading it remembers.

## Ask before working around a limit

Quotas, queue limits, walltime ceilings and authentication requirements exist for
reasons, often ones you cannot see from your account. If one blocks legitimate work,
**describe the use case and ask** — administrators can frequently grant an exception, a
different partition, or a better approach entirely. Silently engineering around a control
is how a reasonable workaround becomes an incident report.

A concrete example, for unattended job submission under interactive two-factor
authentication:

> Would it be possible to exempt the VPN subnet from `keyboard-interactive`
> authentication — a `Match Address` block restricting `AuthenticationMethods` to
> `publickey` — or to document an exception for automated submission? We submit SLURM
> jobs from a pipeline, and a six-digit code cannot be typed by a non-interactive
> process. Happy to describe the workflow and to accept a restricted key.

Note the shape: what you need, why, the specific mechanism you are proposing, and an
offer to accept constraints. That is much easier to say yes to than "2FA is blocking us".

The same shape works for a new software module, more scratch, a longer walltime, or
access to a partition.

## Giving feedback that is worth reading

- **Report the near misses too.** Documentation that is out of date, an error message
  that misleads, a default that surprised you — these are cheap to fix and nobody else
  will mention them.
- **Answer the user survey.** It is often what justifies the next hardware purchase or
  the next staff position.
- **Say when something works.** Support teams hear almost exclusively about failures.
- **Attend the user meeting** if there is one. Ten minutes there can redirect a plan that
  would otherwise waste weeks.
- **Acknowledge the facility in your papers** in the form it asks for, and tell the team
  when a paper comes out. Publications are the metric funders count.

## Before you file

A short checklist that resolves a surprising share of problems:

1. Is there a maintenance or outage announced on the status page or mailing list?
2. Does the job's own `.err` file explain it? `OUT_OF_MEMORY`, `TIMEOUT` and a non-zero
   exit code each have an obvious next step.
3. Are you over quota — bytes *or* inodes?
4. Does it still fail with a minimal script on a small allocation?
5. Did it work before, and what changed on your side (a module default, an environment,
   a new dependency)?

If the answer to all five is "no reason found", you have exactly the report an
administrator needs.
