; This program and the accompanying materials are made available under the
; terms of the MIT license (X11 license) which accompanies this distribution.

; Author: C. Bürger

#!r6rs

(library
 (siple state)
 (export
  make-state
  state-current-frame
  state-current-frame-set!
  state-std-out
  state-std-out-set!
  state-allocate
  state-access
  make-frame
  frame-procedure
  frame-closure
  frame-environment
  frame-environment-set!
  frame-return-value
  frame-return-value-set!
  make-memory-location
  memory-location-value
  memory-location-value-set!)
 (import (rnrs) (racr))
 
 (define-record-type state
   (fields (mutable current-frame) (mutable std-out)))
 
 (define state-allocate
   (lambda (state decl value)
     (let* ((env (frame-environment (state-current-frame state)))
            (entry (assq decl env)))
       (if entry
           (memory-location-value-set! (cdr entry) value)
           (frame-environment-set! (state-current-frame state) (cons (cons decl (make-memory-location value)) env))))))
 
 (define state-access
   (lambda (state decl)
     (let loop ((frame (state-current-frame state)))
       (let ((entity (assq decl (frame-environment frame))))
         (if entity
             (cdr entity)
             (if (frame-closure frame)
                 (loop (frame-closure frame))
                 (assertion-violation
                  'state-access
                  (string-append "SiPLE interpreter implementation error: Access to unallocated variable [" (ast-child 1 decl) "].")
                  (list state decl))))))))
 
 (define-record-type frame
   (fields procedure closure (mutable environment) (mutable return-value)))
 
 (define-record-type memory-location
   (fields (mutable value))))