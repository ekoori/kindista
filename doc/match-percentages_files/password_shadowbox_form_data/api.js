(function(){function d(a){var b=document.createElement("script");b.src=a;b.type="text/javascript";b.async=!0;a=document.getElementsByTagName("script")[0];a.parentNode.insertBefore(b,a)}function e(a){var b=a[0];"_setUser"==b?window.stathat_user_key=a[1]:"_trackCount"==b?d(document.location.protocol+"//api.stathat.com/c?ukey="+window.stathat_user_key+"&key="+a[1]+"&count="+a[2]+"&s=js"):"_trackValue"==b&&d(document.location.protocol+"//api.stathat.com/v?ukey="+window.stathat_user_key+"&key="+a[1]+"&value="+
a[2]+"&s=js")}var c;for(c=0;c<_StatHat.length;c+=1)e(_StatHat[c]);_StatHat={push:function(a){e(a)}}})();