# Bring a Dock Notch release to your own build

You're helping someone whose Dock Notch was built from scratch with a coding agent, from
the project's PROMPT.md, rather than from its source. A newer release is out, and they'd
like what it added or changed. Their code isn't upstream's, so there's nothing to merge:
you'll read what changed in the spec and make the same change in their app, their way.

You need two things. Ask for whichever you don't have:

1. **The difference** between the PROMPT.md they built from and the new one. GitHub shows
   it at `https://github.com/rikuws/dock-notch/compare/v<theirs>...v<new>` (the PROMPT.md
   part), or with git: `git diff v<theirs> v<new> -- PROMPT.md CHANGELOG.md`. Their README
   should say which version they built from.
2. **Their app**: this project. Read its README and the code before changing anything.

## How to port it

- Treat each changed passage of PROMPT.md as a feature request, and CHANGELOG.md's notes
  for the release as the summary of why.
- Where their app already differs on purpose (their README, or a "Your changes" section in
  their copy of PROMPT.md, says so), keep their version and fit the new behavior around
  it. If the two can't both hold, ask which they'd like.
- Make each change as its own commit, so they can keep or drop it.
- Check it the way PROMPT.md's "Checking your work" says, then run the app.
- Update their README to say which version they're now on.

Tell them in a few lines what you brought over, what you left out or did differently, and
why.
