# ITNEXT submission package

Companion to `article-itnext.md`.  Everything an editor or the Medium editor needs.

## Title and subtitle

ITNEXT asks writers to spend time on the headline, and Medium disqualifies a story from
Boost when the title, subtitle or cover image do not represent it well.  The old headline,
"My Mac Was Reading 90 GB an Hour.  The SSD Was Fine.", fails that test: the article walks
the 90 GB figure back in its 3rd paragraph, and the story is not really about the SSD.

Ranked options:

1. **Sixty-Two Days Without a Backup, and Nothing Reported a Problem**
   *A macOS disk-pressure incident, the three tools that misled me, and the four monitoring mistakes I made afterwards.*
   Leads with the finding that matters, promises the engineering content in the subtitle.

2. **The Monitor That Could Only Ever Report Success**
   *How a full disk killed two months of backups, and why the check I wrote to catch it told me everything was fine.*
   Leads with the transferable lesson.  Strongest fit for ITNEXT's audience, weakest at
   telling a feed reader what the piece concerns.

3. **A Full Disk, Two Months of Dead Backups, and Four Monitoring Mistakes**
   *What macOS reports when Time Machine has not completed a backup since July: nothing at all.*
   Most literal.  Least interesting.

## Cover image

ITNEXT requires one.  Use `assets/fig-chain.png`, which is original work, needs no
attribution, and states the article's mechanism in one frame.

## Figure placement and ALT text

`assets/README.md` carries stale ALT text for the 1st figure: it describes macOS "being
unable to grow a swapfile", which is the mechanism the article now explicitly declines to
claim, and which the rendered figure no longer says either.  Use the text below instead.

| File | Placement | ALT text |
|---|---|---|
| `fig-chain.png` | Cover, and again under "How much of the failure chain can I actually support?" | Six-step diagram running from a disk passing 90 percent full, through lost headroom and saturated memory, to page-cache eviction, sustained re-reads at 18 MB/s, and kernel stalls with watchdog timeouts.  A footnote marks the 1st and 3rd steps as measured and the link between them as inference. |
| `fig-ratio.png` | Under "What did SMART actually establish?" | Bar chart comparing 39.5 TB read against 13.8 TB written over 438 powered-on hours, roughly 90 GB per hour. |
| `fig-inversion.png` | Under "What does a re-seed cost, and what drives that cost?", after the table | Two ranked bar charts showing four directories reordering completely between a ranking by size and a ranking by file count. |
| `fig-timeline.png` | Under "When did a backup last actually complete?" | Timeline of completed backups during 2026, ending on 6 July, followed by a 62-day gap with no completed backup. |
| `fig-scoreboard.png` | End of "What does a re-seed cost, and what drives that cost?" | Four before-and-after tiles: free space 36.6 GB to 116.7 GB, swap available 0 MB to 3,072 MB, last backup 62 days to today, backup duration 10.5 hours to 5 to 10 minutes. |

Optional: the rendered figure captions use em dashes, which do not match the article's
prose.  Regenerate from `figures.html` if that inconsistency is worth the pass.

## Tags

Medium disqualifies a story from General Distribution for tagging topics it does not
address.  All five below are load-bearing in the article:

`macOS` · `Backup` · `Debugging` · `Monitoring` · `Software Engineering`

## Sources credited in the text

- [smartmontools issue #176](https://github.com/smartmontools/smartmontools/issues/176), for the Darwin NVMe log-page limitation
- Apple's `IOKit/IOReturn.h`, for the IOKit error space and `kIOReturnDeviceError`

## Disclosures

Both are ITNEXT requirements, not optional courtesies.

1. **Relationship.**  The article names `sparkling-clean`, which is the author's own work.
   Stated plainly in the closing section rather than implied by the link.
2. **Published elsewhere.**  A draft of this article is public in the repository at
   `docs/article-draft.md`.  This is not a Medium duplicate-content problem, since that
   rule applies to Medium only and Medium explicitly permits syndicating your own work,
   but ITNEXT asks to be told.

## Pitch email

To: `submit@itnext.io`
Subject: Submission: a macOS backup outage and four monitoring mistakes

> Hello,
>
> I would like to contribute an article to ITNEXT.  It falls under the "Failure" format
> you list, being an account of an incident on my own development machine and of what I
> got wrong afterwards while building the monitoring for it.
>
> A full disk caused macOS to purge the local snapshot that Time Machine uses as its
> incremental reference, after which every backup failed for sixty-two days while System
> Settings continued to report "Time Machine: On".  The article covers the diagnosis, the
> three places the tooling misled me (a SMART error that is a tool artifact, `df` reporting
> container-wide figures, and Finder counting purgeable space as free), and the four
> mistakes I made in the check I then wrote, the last of which reported healthy for
> thirty-three hours across nineteen consecutive failed backups.
>
> Two disclosures.  The article names a small toolkit that is my own work, stated as such
> in the text; the promotional material has been removed and what remains is five commands
> that need nothing installed.  A draft is also public in my GitHub repository, which I
> mention in case it affects your view of prior publication.
>
> I have written developer documentation for internal audiences for some years, including
> a health-check framework for Spring Boot services built around the same distinction this
> article turns on, between a system that assesses itself and one that merely answers when
> probed.
>
> Five original figures accompany the piece, along with a cover image.  Happy to send the
> draft in whatever form suits you.
>
> Regards,
> Don Jeffery

## Compliance checklist

| Requirement | Source | Status |
|---|---|---|
| No AI-written article | ITNEXT | Rewritten in the author's voice; author's final pass still required |
| No sales pitch | ITNEXT | Install instructions and CLI tour removed; one closing link retained |
| Cover photo | ITNEXT | `fig-chain.png` |
| Bold section titles, content divided by subtitles | ITNEXT | 13 sections, 12 of them reader-voiced questions |
| Sources credited | ITNEXT | smartmontools issue, Apple IOReturn.h |
| Relationship transparency | ITNEXT | Closing section |
| Told if submitted elsewhere | ITNEXT | In the pitch email |
| Clear storyline, straight to the point | ITNEXT | 2,849 prose words against 3,754 |
| Title represents the story | Medium Boost | Headline no longer contradicted in the 3rd paragraph |
| Not sensational or clickbait | Medium | No superlatives, no withheld reveal |
| Images add value, ALT text, credited | Medium Boost | Five original figures, ALT text above |
| Topics tagged honestly | Medium General Distribution | Five relevant tags |
| Not primarily traffic or signups | Medium General Distribution | One link, in a scope-limits section |
| Free of errors | Medium Boost | Needs a proofread pass |
| AI-assistance disclosure | Medium AI policy | Not required if the published prose is the author's own; required if AI-drafted passages survive |
