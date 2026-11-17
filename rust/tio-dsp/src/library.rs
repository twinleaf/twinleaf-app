//! The functions a spec may call: the public ones this crate ships, and
//! whatever a private build adds beside them.
//!
//! A function has two halves. How it is written and how its result is typed
//! is a [`Builtin`], which the checker reads. What computes it is a
//! [`Node`], which the engine runs. For the public functions both halves
//! are in this crate. A private build gives both for each function it adds,
//! and gets back everything else here unchanged: the language, the checker
//! and its diagnostics, the engine, the device and its RPCs, the command
//! line. Its algorithms stay in its own binary, and what leaves that binary
//! is a TIO device like any other.

use crate::lang::builtins::{Builtin, Rule, Signals, BUILTINS};
use crate::lower::{Call, RUNNABLE};
use crate::node::Node;
use std::collections::HashSet;
use std::fmt;
use std::sync::{Arc, Mutex, OnceLock};

/// Makes the node behind one call of a function. What it returns in error
/// is said of the call, at its place in the spec.
pub type Build = dyn Fn(&Call<'_>) -> Result<Box<dyn Node>, String> + Send + Sync;

struct Added {
    builtin: Builtin,
    build: Arc<Build>,
}

/// The functions a spec may call.
#[derive(Clone)]
pub struct Library {
    name: &'static str,
    added: Arc<Vec<Added>>,
    trusting: bool,
}

impl Library {
    /// The public functions and no others.
    pub fn standard() -> Self {
        Self {
            name: "tiodsp",
            added: Arc::new(Vec::new()),
            trusting: false,
        }
    }

    /// What a build that has this library calls itself: on its command
    /// line, and as the device it serves.
    pub fn named(mut self, name: &'static str) -> Self {
        self.name = name;
        self
    }

    pub fn name(&self) -> &'static str {
        self.name
    }

    /// Adds a function. `function` says how it is written and how its
    /// result is typed, and `build` makes the node for one call of it.
    ///
    /// The node must give the type the function's rule promises: the engine
    /// is held to what the checker decided, and a call whose node disagrees
    /// does not build. A name that is already taken is refused, so a
    /// private function cannot quietly stand in for a public one. So is a
    /// function that takes more than one signal or changes the rate, which
    /// only the public ones can do yet.
    pub fn with<F>(mut self, function: Builtin, build: F) -> Result<Self, String>
    where
        F: Fn(&Call<'_>) -> Result<Box<dyn Node>, String> + Send + Sync + 'static,
    {
        let plain = |name: &str| {
            name.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
                && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        };
        if !plain(function.name) {
            return Err(format!(
                "`{}` is not a name a spec can write",
                function.name
            ));
        }
        if self.find(function.name).is_some() {
            return Err(format!("there is already a function `{}`", function.name));
        }
        // The rules that change the rate or join signals read the public
        // functions' own arguments and make their domains. They are not
        // open to others yet.
        let plain_rule = matches!(
            function.rule,
            Rule::Same | Rule::Magnitude | Rule::Integrates | Rule::Differentiates
        );
        if !plain_rule || function.signals != Signals::One || function.named_signal.is_some() {
            return Err(format!(
                "`{}` must take one signal and keep its rate: its rule can be `Same`, \
                 `Magnitude`, `Integrates` or `Differentiates`",
                function.name
            ));
        }
        for (index, arg) in function.args.iter().enumerate() {
            if !plain(arg.name) || function.args[..index].iter().any(|a| a.name == arg.name) {
                return Err(format!(
                    "`{}` has an argument called `{}` twice, or one that is not a name",
                    function.name, arg.name
                ));
            }
        }
        let mut added: Vec<Added> = self
            .added
            .iter()
            .map(|added| Added {
                builtin: added.builtin,
                build: Arc::clone(&added.build),
            })
            .collect();
        added.push(Added {
            builtin: function,
            build: Arc::new(build),
        });
        self.added = Arc::new(added);
        Ok(self)
    }

    /// Takes a function it does not know on trust: a call of one is typed
    /// as passing its input on, and remarked on rather than refused.
    ///
    /// This is for reading a text bound for a graph that may know more
    /// functions than this build does, as an editor must. The graph that
    /// runs the text checks it with its own library and has the last word.
    pub fn trusting(mut self) -> Self {
        self.trusting = true;
        self
    }

    pub fn is_trusting(&self) -> bool {
        self.trusting
    }

    /// The function called `name`.
    pub fn find(&self, name: &str) -> Option<&Builtin> {
        BUILTINS
            .iter()
            .chain(self.added.iter().map(|added| &added.builtin))
            .find(|builtin| builtin.name == name)
    }

    /// Every function, the public ones first.
    pub fn functions(&self) -> impl Iterator<Item = &Builtin> {
        BUILTINS
            .iter()
            .chain(self.added.iter().map(|added| &added.builtin))
    }

    /// Whether there is signal processing behind a function. Some public
    /// ones are checked and cannot run yet.
    pub fn runs(&self, name: &str) -> bool {
        RUNNABLE.contains(&name) || self.build(name).is_some()
    }

    /// What makes the node of a function that was added.
    pub(crate) fn build(&self, name: &str) -> Option<&Build> {
        self.added
            .iter()
            .find(|added| added.builtin.name == name)
            .map(|added| &*added.build)
    }
}

impl Default for Library {
    fn default() -> Self {
        Self::standard()
    }
}

impl fmt::Debug for Library {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let added: Vec<&str> = self.added.iter().map(|added| added.builtin.name).collect();
        f.debug_struct("Library")
            .field("name", &self.name)
            .field("added", &added)
            .field("trusting", &self.trusting)
            .finish()
    }
}

/// Two libraries are the same when they are one library: functions cannot
/// be compared, only told apart.
impl PartialEq for Library {
    fn eq(&self, other: &Self) -> bool {
        self.name == other.name
            && self.trusting == other.trusting
            && Arc::ptr_eq(&self.added, &other.added)
    }
}

/// A name that lasts as long as the program, for a function taken on
/// trust. Each name is kept once, however often it is read.
pub(crate) fn remembered(name: &str) -> &'static str {
    static NAMES: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();
    let mut names = NAMES
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match names.get(name) {
        Some(kept) => kept,
        None => {
            let kept: &'static str = Box::leak(name.to_owned().into_boxed_str());
            names.insert(kept);
            kept
        }
    }
}
