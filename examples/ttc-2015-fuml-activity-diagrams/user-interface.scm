; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(library
 (ttc-2015-fuml-activity-diagrams user-interface)
 (export run-activity-diagram)
 (import (rnrs) (racr core) (racr testing)
         (ttc-2015-fuml-activity-diagrams language)
         (ttc-2015-fuml-activity-diagrams parser)
         (prefix (atomic-petrinets analyses) pn:)
         (prefix (atomic-petrinets user-interface) pn:))
 
 (define (run-activity-diagram diagram-file input-file mode) ; Execute diagram & print trace.
   (define activity (parse-diagram diagram-file))
   (when input-file
     (for-each
      (lambda (n)
        (define variable (=v-lookup activity (->name n)))
        (unless variable (exception: "Unknown Input"))
        (unless (eq? (->initial variable) Undefined) (exception: "Unknown Input"))
        (rewrite-terminal 'initial variable (->initial n)))
      (parse-diagram-input input-file)))
   (unless (for-all (lambda (n) (not (eq? (->initial n) Undefined))) (=variables activity))
     (exception: "Missing Input"))
   (when (> mode 1)
     (unless (=valid? activity) (exception: "Invalid Diagram"))
     (when (> mode 2)
       (let ((net (=petrinet activity)))
         (when (> mode 3)
           (unless (pn:=valid? net) (exception: "Invalid Diagram"))
           (when (> mode 4)
             (trace (->name (=initial activity)))
             (if (= mode 5)
                 (pn:run-petrinet! net)
                 (do ((enabled (filter pn:=enabled? (pn:=transitions net))
                               (filter pn:=enabled? (pn:=transitions net))))
                   ((null? enabled))
                   (for-each pn:fire-transition! enabled)))
             (for-each
              (lambda (n) (trace (->name n) " = " ((=v-accessor n))))
              (=variables activity))))))))
 
 (pn:initialise-petrinet-language))