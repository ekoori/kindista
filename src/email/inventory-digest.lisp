;;; Copyright 2015 CommonGoods Network, Inc.
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

;(defun subscribe-current-users-to-inventory-digest
;  (&aux (subscribed-count 0))
;  "subscribe for users who receive either kindista notifications or activity reminders."
;  (dolist (userid *active-people-index*)
;    (let ((user (db userid)))
;      (if (or (getf user :notify-kindista)
;                (getf user :notify-reminders))
;        (progn
;          (modify-db userid :notify-inventory-digest t)
;          (incf subscribed-count))
;        (modify-db userid :notify-inventory-digest nil))))
;  subscribed-count)


(defvar *last-inventory-digst-mailer-time* 0)

(defun get-daily-inventory-digest-mailer
  (&aux (day (local-time:timestamp-day-of-week (local-time:now))) )
  (when (and *productionp*
             ;; wait if last called less than 22 hours ago
             ;;(in case of daylight savings time)
             (< *last-inventory-digst-mailer-time*
                (- (get-universal-time) 79200))
             (or (getf *user* :admin)
               (string= (header-in* :x-real-ip) *local-ip-address*)
               (string= (header-in* :x-real-ip) "127.0.0.1")))
    (setf *last-inventory-digst-mailer-time* (get-universal-time))
    (dolist (userid *active-people-index*)
      ;; get 1/7th of the userbase
      (when (= (mod userid 7) day)
        (send-inventory-digest-email userid)))))

(defun send-inventory-digest-email
  (userid
   &aux (user (db userid))
        (inventory-items (recent-local-inventory userid :user user))
        (offers (getf inventory-items :offers))
        (requests (getf inventory-items :requests))
        (email (first (getf user :emails)))
        (text (inventory-digest-email-text userid
                                           inventory-items
                                           :user user))
        (html (inventory-digest-email-html userid
                                           inventory-items
                                           :user user)))
  (when email
    (cl-smtp:send-email +mail-server+
                        "Kindista <info@kindista.org>"
                         (format nil "\"~A\" <~A>" (getf user :name) email)
                         (strcat* "Recent Kindista "
                                  (when offers " Offers ")
                                  (when (and offers requests) "and")
                                  (when requests " Requests ")
                                  "in Your Area")
                         text
                         :html-message html)))

(defun recent-local-inventory
  (userid
   &key (user (db userid))
        (timeframe +week-in-seconds+)
   &aux (distance (min 50 (max 5 (or (getf user :rdist) 25))))
        (lat (getf user :lat))
        (long (getf user :long))
        (now (get-universal-time))
        offer-count
        request-count
        offers
        requests)
  "Returns up to 24 recent inventory items."

  (when (and (getf user :location) lat long)
    (labels ((rank (item)
               (activity-rank item :user user
                                   :contacts (getf user :following)
                                   :contact-multiplier 4
                                   :distance-multiplier 6
                                   :lat lat
                                   :long long))
             (get-inventory (index)
               (sort (remove-if #'(lambda (result)
                                    (or (find userid (result-people result))
                                        (< (result-time result)
                                           (- now timeframe))
                                        (item-view-denied
                                          (result-privacy result)
                                          userid)))
                                (geo-index-query index lat long distance))
                     #'<
                     :key #'rank)))

      (setf offers (get-inventory *offer-geo-index*))
      (setf offer-count (length offers))
      (setf requests (get-inventory *request-geo-index*))
      (setf request-count (length requests))

      (cond
        ((and (> offer-count 11)
              (> request-count 11))
         (asetf offers (subseq it 0 12))
         (asetf requests (subseq it 0 12)))
        ((< request-count 12)
         (asetf offers (subseq it 0 (min (- 25 request-count)
                                         offer-count))))
        ((< offer-count 12)
         (asetf requests (subseq it 0 (min (- 25 offer-count)
                                           request-count)))))

      (list :offers (mapcar #'result-id offers)
                   ;(mapcar #'(lambda (result)
                   ;            (cons (result-id result)
                   ;                  (rank result)))
                   ;        offers)
            :requests (mapcar #'result-id requests)
                     ;(mapcar #'(lambda (result)
                     ;            (cons (result-id result)
                     ;                  (rank result)))
                     ;        requests)
            ))))

(defun inventory-digest-email-text
  (userid
   recent-items
   &key (user (db userid))
   &aux (name (getf user :name))
        (offers (getf recent-items :offers))
        (requests (getf recent-items :requests)))

(labels ((item-text (item-id)
           (email-inventory-item-plain-text item-id :user user)))

  (strcat* "Hi " name ","
           #\linefeed #\linefeed
           "Here are some"
           (when offers " offers ")
           (when (and offers requests) "and")
           (when requests " requests ")
           "your neighbors have posted to Kindista during the past week. "
           "You are currently subscribed to receive notifications about items posted within "
           (getf user :rdist)
           " miles. You can change this distance on your settings page: "
           *email-url*
           "settings/communication#digest-distance"
           (when offers
             (strcat #\linefeed #\linefeed
                     "OFFERS"
                     #\linefeed
                     (apply #'strcat (mapcar #'item-text offers))))
           (when requests
             (strcat* #\linefeed
                      (unless offers #\linefeed)
                      "REQUESTS"
                      #\linefeed
                      (apply #'strcat (mapcar #'item-text requests))))
           (amazon-smile-reminder)
           (unsubscribe-notice-ps-text (getf user :unsubscribe-key)
                                       (car (getf user :emails))
                                       "email summaries of new offers and requests in your area")
         )))

(defun inventory-digest-email-html
  (userid
    recent-items
    &key (user (db userid))
    &aux (offers (getf recent-items :offers))
         (requests (getf recent-items :requests)))

  (html-email-base
    (html
      (:p :style *style-p*
       "Hi " (str (getf user :name)) ",")

      (:p :style *style-p*
       "Here are some "
       (str (s+ (when offers " offers ")
                (when (and offers requests) "and")
                (when requests " requests ")))
       "your neighbors have posted to Kindista during the past week. "
       "You are currently subscribed to receive notifications about items posted within "
       (str (getf user :rdist))
       " miles. You can change this distance on your "
       (:a :href (s+ *email-url* "settings/communication#digest-distance")
        "settings page")
       ".")

      (:h2 "OFFERS")

      (dolist (offer offers)
        (str (email-inventory-item-html offer :user user)))

      (:h2 "REQUESTS")

      (dolist (request requests)
        (str (email-inventory-item-html request :user user)))

      (str (amazon-smile-reminder t))

      (str (unsubscribe-notice-ps-html
             (getf user :unsubscribe-key)
             (car (getf user :emails))
             "email summaries of new offers and requests in your area")))))

(defun email-inventory-item-html
  (id
   &key (item (db id))
        user
   &aux (type (getf item :type))
        (result (gethash id *db-results*))
        (item-lat (result-latitude result))
        (item-long (result-longitude result))
        (user-lat (getf user :lat))
        (user-long (getf user :long))
        (distance (when (and item-lat item-long user-lat user-long)
                    (distance-string
                      (air-distance item-lat item-long user-lat user-long))))
        (title (getf item :title))
        (typestring (string-downcase (symbol-name type)))
        (response-type (if (eq type :offer) "request" "offer"))
        (url (strcat *email-url* typestring "s/" id))
        (author (db (getf item :by))))
  "Link title, action button, no other links"

  (html
    (:div :style (s+ *style-p* "border-top: 1px solid #eee;")
      (:div :style "margin: 0.7em 0 0.3em;"
        (awhen title
          (htm
            (:img :src (s+ "http://media.kindista.org/"
                           typestring
                           "s.png")
                  :alt typestring
                  :style "width: 1.47em; height: 1.47em; margin-right: 0.3em;")
            (:h3 :style "font-size: 1.1em; margin-bottom: 0.3em; display: inline;"
              (:a :href url
                  :style "color: #5c8a2f; font-weight: bold; text-decoration: none;"
                  (str it))))))
      (:div :style "margin-bottom: 1em;"
        (htm
          (str (s+ typestring "ed by "))
          (str (getf author :name))
          (awhen distance
            (htm
              (:span :style "font-size: 0.8em;"
                (str (strcat " (within " it ")")))))))
      (:div
        (str (ellipsis (getf item :details) :see-more url :email t)))

      (:div
        (:form :method "post" :action url
               (:button :type "submit"
                        :style "text-shadow: 1px 1px rgba(0,0,0,0.4);
                                margin: 0.9em 0.5em 0 0;
                                font-size: 0.8em;
                                padding: 0.3em 0.4em;
                                background: #3c6dc8;
                                vertical-align: middle;
                                cursor: pointer;
                                background: -moz-linear-gradient(
                                 top,
                                 #3c6dc8 0%,
                                 #29519c);
                                background: -ms-linear-gradient(
                                 top,
                                 #3c6dc8 0%,
                                 #29519c);
                                background: -o-linear-gradient(
                                 top,
                                 #3c6dc8 0%,
                                 #29519c);
                                background: -webkit-linear-gradient(
                                 top,
                                 #3c6dc8 0%,
                                 #29519c);
                                background: -webkit-gradient(
                                 linear, left top, left bottom,
                                 from(#3c6dc8),
                                 to(#29519c));
                                border: 1px solid #474747;
                                text-shadow:
                                 1px 1px 2px rgba(0,0,0,0.4);
                                border-radius: 0.35em;
                                color: #fff;
                                box-shadow: 1px 1px 0px rgba(255,255,255,0.2), inset 1px 1px 0px rgba(209,209,209,0.3);"
                        :name "action-type"
                        :value typestring
                        (:img :src (s+ "http://media.kindista.org/white-"
                                       response-type
                                       ".png")
                              :alt response-type
                              :style "vertical-align: middle; width: 1.47em; height: 1.47em; margin-right: 0.3em;" 
                         ) 
                        ;; following needs div instead of span because of a
                        ;; firefox hover/underline bug
                        (:div :style "display: inline; font-weight: bold;"
                          (str (s+ (string-capitalize response-type) " This")))))))))

(defun email-inventory-item-plain-text
  (id
   &key (item (db id))
        user
   &aux (type (getf item :type))
        (result (gethash id *db-results*))
        (item-lat (result-latitude result))
        (item-long (result-longitude result))
        (user-lat (getf user :lat))
        (user-long (getf user :long))
        (distance (when (and item-lat item-long user-lat user-long)
                    (distance-string
                      (air-distance item-lat item-long user-lat user-long))))
        (typestring (symbol-name type))
        (author (db (getf item :by))))

  (strcat*
    #\linefeed
    (awhen (getf item :title) it)
    #\linefeed
    (string-capitalize (string-downcase typestring))
    "ed by "
    (getf author :name)
    (awhen distance
      (strcat " (within " it ")"))
    #\linefeed
    #\linefeed
    (ellipsis (getf item :details) :plain-text t)
    #\linefeed
    "Link: "
    +base-url+
    (string-downcase typestring)
    "s/"
    id
    #\linefeed
    "------------------------------------"
    #\linefeed))

