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

(defun send-matching-offer-notification-email (offer-id request-id)
  (let* ((request (db request-id))
         (requested-by (db (getf request :by)))
         (email (car (getf requested-by :emails)))
         (unsubscribe-key (getf requested-by :unsubscribe-key))
         (title (getf request :title)))

     (when (or *productionp* (getf requested-by :admin))
       (cl-smtp:send-email +mail-server+
                          "DoNotReply <noreply@kindista.org>"
                          email
                          (s+ "New Kindista offer matching your request"
                              (awhen title
                                (s+ ": " it)))
                          (matching-offer-notification-email-text
                            request-id
                            offer-id
                            email
                            unsubscribe-key)
                          :html-message (matching-offer-notification-email-html
                                          request-id
                                          offer-id
                                          email
                                          unsubscribe-key)))))

(defun matching-offer-notification-email-text (request-id offer-id email unsubscribe-key)
  (let ((offer (db offer-id))
        (request (db request-id)))
    (strcat*
      (no-reply-notice)
      #\linefeed
      "Hey " (db (getf request :by) :name) ","
      #\linefeed #\linefeed
      "Great news! "
      "Someone just posted an offer that matches your request."
      #\linefeed #\linefeed
      "Here's what was posted:"
      (awhen (getf offer :title)
        #\linefeed #\linefeed 
        it)
      #\linefeed
      "\""
      (getf offer :details)
      "\""
      #\linefeed #\linefeed
      "Here's a link to the offer if you want to check it out or ask to receive it:"

      #\linefeed
      (strcat *email-url* "offers/" offer-id)
      #\linefeed #\linefeed
      "This offer matches your request:"
      (awhen (getf request :title)
        #\linefeed #\linefeed
        it)
      #\linefeed
      "\""
      (or (getf request :details) (getf request :text))
      "\""
      #\linefeed #\linefeed
      "Thank you for sharing your gifts with us!"
      #\linefeed
      "-The Kindista Team"
      #\linefeed #\linefeed
      "If you no longer wish to receive notifications regarding this request, you can change your matchmaker notification preferences here:"
      #\linefeed
      (url-compose (strcat *email-url* "requests" request-id)
                   "selected" "matchmaker"
                   "email" email
                   "k" unsubscribe-key))))


(defun matching-offer-notification-email-html (request-id offer-id email unsubscribe-key)
  (let* ((offer-link (strcat *email-url* "offers/" offer-id))
         (request-link (url-compose (strcat *email-url* "requests/" request-id)
                                    "selected" "matchmaker"
                                    "email" email
                                    "k" unsubscribe-key))
         (request (db request-id))
         (match-terms (union (getf request :match-all-terms)
                             (getf request :match-any-terms))))
    (html-email-base
      (html
        (:p :style *style-p* (:strong (str (no-reply-notice))))

        (:p :style *style-p*
          "Hi " (str (db (getf request :by) :name)) ",")

        (:p :style *style-p*
           "Great news! Someone just posted an "
           (:a :href offer-link "offer")
           " that matches your request.")

        (:p :style *style-p*
           "Here's what was posted:")

        (:table :cellspacing 0 :cellpadding 0
                :style *style-quote-box*
          (:tr (:td :style "padding: 4px 12px;"
                 (str (highlight-relevant-inventory-text offer-id
                                                         request-id
                                                         :email-p t))))

          (:tr (:td :style (s+ "padding: 4px 12px; text-align: right;")
                 (:a :href offer-link "see more details")
                 " or "
                 (:a :href (s+ offer-link "/reply") "ask to receive this"))))

        (:p :style *style-p*
           "This offer matches your request:")

        (:table :cellspacing 0 :cellpadding 0
                :style *style-quote-box*
          (awhen (getf request :title)
            (htm (:tr (:td :style "padding: 4px 12px;"
                        (:a :href request-link (str it))))))
          (:tr (:td :style "padding: 4px 12px;"
                 (str (getf request :details))))
          (:tr (:td :style (s+ "padding: 4px 12px;")
                (:span
                  (:strong "matchmaker terms:  ")
                  (str (dolist (term match-terms)
                         (htm (str term))
                         (unless (eql term (car (last match-terms)))
                           (htm " · "))))))))

        (:p :style *style-p* "Thank you for sharing your gifts with us!")

        (:p "-The Kindista Team")

        (:p :style (s+ *style-p* " font-size: 0.85em;")
          "If you no longer wish to receive notifications regarding this request, you can change your matchmaker notification preferences here:"
         (:br)
         (:a :href request-link (str request-link)))))))

