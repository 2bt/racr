; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(library
 (ttc-2015-fuml-activity-diagrams user-interface)
 (export parse)
 (import (rnrs) (racr testing) (ttc-2015-fuml-activity-diagrams parser))
 
 (define (parse f)
   (parse-diagram f)));(print-ast (tparse "examples/correct/test1.ad") (list) (current-output-port))