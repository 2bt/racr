# Examples Overview

**Beware:** _RACR_ must be [installed](../documentation/requirements-and-installation.md) for the examples to work. Examples that are _Scheme_ libraries have to be installed themselves.

**Note:** The following examples are ordered in increasing difficulty.

## Binary Numbers

**Difficult level:** Attribute grammar novice, _RACR_ novice
**New features:** Introduction to synthesised and inherited attributes
**Size:** Very small
**Scheme library:** No, ordinary _Scheme_ top-level program

_RACR_ introduction based on Knuth's classical attribute grammar paper and its "binary to decimal numbers" example. For details about it see: Donald E. Knuth, _Semantics of Context-Free Languages_, Theory of Computing Systems, volume 2, number 2, pages 127-145, Springer, 1968.

Objectives:
  * Introduction to _RACR_:
    * Abstract syntax tree specifications: Non-terminals, productions, inheritance
    * Attribute specifications: Synthesised & inherited attributes
    * Abstract syntax tree & attribute query functions

## State Machines

**Difficult level:** Reference attribute grammar novice, _RACR_ novice
**New features:** Introduction to reference and circular attributes and attribute broadcasting and inheritance
**Size:** Small
**Scheme library:** No, ordinary _Scheme_ top-level program
**Web documentation:** [Implementation summary](state-machines/documentation/state-machines.md)

_RACR_ specification implementing a simple finite state machine language providing attributes to search for certain states by name, to compute the direct successors of a state, the states reachable from it (transitive closure) and if it is a final state. Also the well-formedness of state machines can be checked via attributes. A state machine is well-formed, if, and only if, all states (except the initial state) are reachable from the initial state and from every state (except final states) a final state is reachable.

The example shows, how reference attributes declaratively induce edges on abstract syntax trees, extending them to abstract syntax graphs. Such reference attribute induced edges form semantic overlay graphs and are typical for name and type analyses. In the example, reference attributes are used to 'transform' the abstract syntax tree, which was constructed by parsing a textual state machine representation, to the respective, actual, state machine diagram. The graph resulting from this name analysis is well-suited for further analyses, like the implemented state reachability.

Objectives:
  * Introduction to reference and circular attributes in _RACR_, their typical applications and advantages
    * Reference attributes: Graph analyses
    * Circular attributes: Transitive closure analyses

## _SLE 2015_: _RACR_ motivation and overview example submitted to the _8th ACM SIGPLAN International Conference on Software Language Engineering_

**Difficult level:** RAG-controlled rewriting novice, _RACR_ novice
**New features:** Introduction to rewrites and incremental evaluation
**Size:** Small
**Scheme library:** No, ordinary _Scheme_ top-level program

This example summarises and motivates the essential features of _RACR_ by implementing a simple nested programming language, enriched with type coercion, superfluous cast optimisation and type refactoring. The example shows:
  * How reference attributes extend abstract syntax trees to abstract syntax graphs
  * How dynamic attribute dependencies extend abstract syntax graphs to dynamic attribute dependency graphs
  * The importance and benefits of dynamic dependencies for incremental attribute evaluation
  * How reference attribute grammar analyses can be used to ease the development of transformations

Objectives:
  * Overview of essential _RACR_ features (abstract syntax tree scheme + attribution = abstract syntax graph scheme, rewrites)
  * Self-contained, easy and fast to understand motivation of RAG-controlled rewriting

## Questionnaires: _Language Workbench Challenges 2013 & 2014_

**Difficult level:** RAG-controlled rewriting disciple, _RACR_ disciple
**New features:** Extensive introduction to RAG-controlled rewriting and incremental evaluation
**Size:** Small/Medium
**Scheme library:** Yes

Implementation of the Questionnaire Language, the competition scenario of the [Language Workbench Challenges 2013 and 2014](http://www.languageworkbenches.net). For a description of the scenario consult `./questionnaires/documentation/language-workbench-challenge-2013.pdf`.

Questionnaires, as defined in the _Language Workbench Challenge_, consist of arbitrary many questions. Each question is typed and can be computed, in which case it does not ask users for a value but instead evaluates a given expression and shows the result. Questions can also be part of a group, which means they are only shown if their group condition is true. Groups can be nested. Nesting has no further meaning besides combining group conditions. The value of a question, whether computed or user-given, is only visible for succeeding expressions. The same question is at most shown once. If it can be several times shown, only its first occurrence is active, i.e., shown to users and used in expressions. Questionnaires are statically typed and only well-formed if type correct. The value of unanswered questions is undefined. Computations on undefined yield undefined themselves. If a group condition is undefined, the condition is treated to be _false_.

The _RACR_ solution is unique in several ways:

  * The widgets of the GUI are computed by attributes. The actual rendering, i.e., showing and shadowing of questions and updating of computed results, is realised by attributes and rewrites respectively. In doing so, the rendering automagically becomes incremental, i.e., when drawing the GUI, the application will only re-render the GUI elements that changed since their last rendering (for example if the value of computed questions changed, new answers are typed or question groups are disabled or enabled).
  * Questionnaires are serialized and deserialized as symbolic-expressions, i.e., executable _Scheme_ programs. If executed, these programs construct the abstract syntax tree representing the respective questionnaire and its current answer state.

Thus, each abstract syntax graph is model of both, the given and computed information _and_ their graphical representation. The respective attributes enable a clear encapsulation of language concerns, for which reason a convenient model-view-controller solution is achieved without code mixing, doubling or unnecessary interdependencies. Thereby, the controller is automagically realised by _RACR's_ incremental evaluation.

The solution uses [_Racket_](http://racket-lang.org) libraries for its GUI implementation, for which reason it only works with _Racket_.

Objectives:
  * Simple models@runtime example introducing _RACR_-based incremental evaluation:
    * Encoding of state in abstract syntax trees (model of real world: questions presented in a GUI to a user)
    * State changes via rewriting (model updates: user answers)
    * State reasoning and reaction on changes via attributes (model reasoning to derive real world actions: computation of expression values & re-rendering of GUI elements if necessary)

## Petri Nets

**Difficult level:** Reference attribute grammar disciple, Rewrite disciple, _RACR_ disciple
**Size:** Medium
**Scheme library:** Yes

_RACR_ specification implementing coloured, weighted Petri nets that can be composed using place fusion and support arbitrary input arc conditions and output computations. A reference attribute grammar is used to perform name, enabled, composition and well-formedness analyses of Petri nets and their transitions. _RACR_ rewrites are used to implement their actual execution semantics, i.e., the firing of enabled transitions. A user friendly interface for the specification of Petri nets and their composition and execution is provided in the form of _Scheme_ macros. _RACR_'s incremental attribute evaluation ensures an optimised and efficient enabled analysis, even in case of arbitrarily intertwined compositions, executions (i.e., transition firing) and decompositions. The implemented composition semantics are based on the concept of in- and output ports as presented by Wolfgang Reisig in _Simple Composition of Nets_, Applications and Theory of Petri Nets: 30th International Conference, Lecture Notes in Computer Science, Volume 5606, Pages 23-42, Springer, June 2009.

Objectives:
  * Introduction to RAG-controlled rewriting & dynamic, incremental reference attribute evaluation:
    * Reference attributes: Name, graph and well-formedness analyses (e.g., the enabled analysis of Petri net transitions)
    * Rewrites: AST represents a state, rewrites are state changes (e.g., rewrites that simulate the firing of transitions by adding and deleting tokens or rewrites that compose Petri nets)
    * Incremental Evaluation: Attributes are only reevaluated if they depend on information changed by rewrite applications (e.g., the enabled status of transitions is only reevaluated if the last fired transition or the last performed composition influenced it)

## SiPLE (Simple imperative Programming Language Example)

**Difficult level:** Reference attribute grammar experienced, Rewriting novice, _RACR_ experienced
**Size:** Medium
**Scheme library:** Yes

SiPLE is a simple imperative programming language. Its language concepts are:
  * Integer, real and Boolean arithmetics
  * Pointers (including pointers to procedures and pointers)
  * A block-structured name space and nested procedures
  * Lexically-scoped first-class functions (i.e., lexical closures)
  * `While` and `If` control-flow statements
  * Automatic integer to real type coercions (e.g., when assigning an integer value to a variable of type real or when adding an integer to a real value)
  * A save interpreter, that calmly terminates in the presence of errors
SiPLE is strongly typed, such that a static type analysis can be performed.
