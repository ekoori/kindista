;;; Copyright 2012-2013 CommonGoods Network, Inc.
;;;
;;; This file is part of Kindista.
;;;
;;; Kindista is free software: you can redistribute it and/or modify it
;;; under the terms of the GNU Affero General Public License as published
;;; by the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; Kindista is distributed in the hope that it will be useful, but WITHOUT
;;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;;; License for more details.
;;;
;;; You should have received a copy of the GNU Affero General Public License
;;; along with Kindista.  If not, see <http://www.gnu.org/licenses/>.

(in-package :kindista)

(defun new-comment-notice-handler ()
  (send-comment-notification-email (getf (cddddr *notice*) :id)))

(defun create-comment (&key on (by *userid*) text (time (get-universal-time)))
  (let* ((id (insert-db (list :type :comment
                             :on on
                             :by (list by) ;(personid . groupid)
                             :text text
                             :created time)))
         (on-type (db on :type))
         (mailbox-states (message-mailboxes (gethash on *db-messages*)))
         (mailboxes (all-message-mailboxes mailbox-states))
         (sender-mailbox (assoc by mailboxes)))

    (flet ((unread-box (mailbox)
             (let ((current-unread-status (cons-assoc mailbox
                                                      (getf mailbox-states
                                                            :unread))))
              (if (cdr current-unread-status)
                current-unread-status
                (cons mailbox id)))))

     (index-message on (modify-db on :latest-comment id
                                     :mailboxes (list :read (list (list sender-mailbox))
                                                      :unread (mapcar #'unread-box (remove sender-mailbox mailboxes :test #'equal))))))

    (when (or (eq on-type :conversation)
              (eq on-type :reply))
      (notice :new-comment :time time :id id))
    id))

(defun delete-comment (id)
  (with-locked-hash-table (*comment-index*)
    (asetf (gethash (getf (db id) :on) *comment-index*) (remove id it)))

  (remove-from-db id))

(defun delete-comments (id)
  (dolist (comment (gethash id *comment-index*))
    (delete-comment comment))
  (with-locked-hash-table (*comment-index*)
    (remhash id *comment-index*)))


(defun latest-comment (id)
  (or (getf (db id) :latest-comment) 0))

(defun index-comment (id data)
  (with-locked-hash-table (*comment-index*)
    (asetf (gethash (getf data :on) *comment-index*) (sort (push id it) #'<))))

(defun comments (id)
  (gethash id *comment-index*))

(defun get-comment-delete (id)
  (require-user
    (setf id (parse-integer id)) 
    (let ((it (db id)))
      (if (eq (getf it :type) :comment)
        (confirm-delete :url (strcat "/comments/" id) :next-url (referer) :type "comment" :text (getf it :text))
        (not-found)))))

(defun post-comment (id)
  (require-user
    (setf id (parse-integer id)) 
    (let ((it (db id)))
      (if (eq (getf it :type) :comment)
        (cond
          ((and (or (eql (getf it :by) *userid*)
                    (getf *user* :admin))
                (post-parameter "really-delete"))
           (delete-comment id) 
           (flash "The comment has been deleted.")
           (see-other (or (post-parameter "next") "/"))) 

          (t
           (flash "You can only delete your own comments." :error t)
           (see-other (or (post-parameter "next") "/"))))
        (not-found)))))
