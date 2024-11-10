## Philosophy

Crane is design to build and and cached Nix'd normalized versions of external
dependencies. As such, it extract external references from the Cargo.lock file
to create the first derivation of them that involves adjusting any hardcoded dates values
to 1980-01-01, ensuring closure (all references are inside the Nix Store), and 
the merid other tune ups that Nix requires to ensure reproducable immutable 
anonomized builds.

A second derivation is perform on the output of the build of the local files
that will now import the anonomize version of the external imports. Other commands
operating over the anonomized external builds are also able to be peformed
such as lints, performing code coverage
analysis, or even generating types from a model schema. 

Let's take a look at two
examples at how very similar configurations can give us very different behavior!
