
Do not merge this branch to the main branch, it only exists to produce docs with the old cli and api content (as hosted on gloo.solo.io) in a way that is compatible with the new versioned scope (docs.solo.io/gloo/0.20)

# About
- This branch is a fork of [feature-rc1](https://github.com/solo-io/gloo/tree/feature-rc1) and should be kept up to date with it
- Whenever we want to release a new form of the v0.20 docs, follow the procedure below (i.e. generate v0.20 api docs from this branch so the result can be hosted at docs.solo.io/gloo/v0.20)

# Procedure
- copy api and cli docs from the master branch of the old docs repo https://github.com/solo-io/solo-docs
  - this branch will be populated by the v0.20 form of the gloo repo
- generate docs images using the docs.solo.io build steps
