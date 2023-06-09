




############# BEGIN SOMEWHAT GENERIC CLASSES ###########################################



# Field of regard requests
var FOR_ROUND  = 0;# TODO: be able to ask noseradar for round field of regard.
var FOR_SQUARE = 1;
#Pulses
var DOPPLER = 1;
var MONO = 0;

var overlapHorizontal = 1.5;


#   █████  ██ ██████  ██████   ██████  ██████  ███    ██ ███████     ██████   █████  ██████   █████  ██████
#  ██   ██ ██ ██   ██ ██   ██ ██    ██ ██   ██ ████   ██ ██          ██   ██ ██   ██ ██   ██ ██   ██ ██   ██
#  ███████ ██ ██████  ██████  ██    ██ ██████  ██ ██  ██ █████       ██████  ███████ ██   ██ ███████ ██████
#  ██   ██ ██ ██   ██ ██   ██ ██    ██ ██   ██ ██  ██ ██ ██          ██   ██ ██   ██ ██   ██ ██   ██ ██   ██
#  ██   ██ ██ ██   ██ ██████   ██████  ██   ██ ██   ████ ███████     ██   ██ ██   ██ ██████  ██   ██ ██   ██
#
#
var AirborneRadar = {
	#
	# This is an base class for an airborne forward looking radar
	# The class RadarMode uses this. Subclass as needed.
	#
	# TODO: Cleaner calls to optional ground mapper
	#
	fieldOfRegardType: FOR_SQUARE,
	fieldOfRegardMaxAz: 60,
	fieldOfRegardMaxElev: 60,
	fieldOfRegardMinElev: -60,
	currentMode: nil, # vector of cascading modes ending with current submode
	currentModeIndex: nil,
	rootMode: 0,
	mainModes: nil,
	instantFoVradius: 2.0,#average of horiz/vert radius
	instantVertFoVradius: 2.5,# real vert radius (could be used by ground mapper)
	instantHoriFoVradius: 1.5,# real hori radius (not used)
	rcsRefDistance: 70,
	rcsRefValue: 3.2,
	#closureReject: -1, # The minimum kt closure speed it will pick up, else rejected.
	#positionEuler: [0,0,0,0],# euler direction
	positionDirection: [1,0,0],# vector direction
	positionCart: [0,0,0,0],
	eulerX: 0,
	eulerY: 0,
	horizonStabilized: 1, # When true antennae ignore roll (and pitch until its high)
	vector_aicontacts_for: [],# vector of contacts found in field of regard
	vector_aicontacts_bleps: [],# vector of not timed out bleps
	chaffList: [],
	chaffSeenList: [],
	chaffFilter: 0.60,# 1=filters all chaff, 0=sees all chaff all the time
	timer: nil,
	timerMedium: nil,
	timerSlow: nil,
	timeToKeepBleps: 13,
	elapsed: elapsedProp.getValue(),
	lastElapsed: elapsedProp.getValue(),
	debug: 0,
	newAirborne: func (mainModes, child) {
		var rdr = {parents: [child, AirborneRadar, Radar]};

		rdr.mainModes = mainModes;

		foreach (modes ; mainModes) {
			foreach (mode ; modes) {
				# this needs to be set on submodes also...hmmm
				mode.radar = rdr;
			}
		}

		rdr.currentModeIndex = setsize([], size(mainModes));
		forindex (var i; rdr.currentModeIndex) {
			rdr.currentModeIndex[i] = 0;
		}

		rdr.setCurrentMode(rdr.mainModes[0][0], nil);

		rdr.SliceNotification = SliceNotification.new();
		rdr.ContactNotification = VectorNotification.new("ContactNotification");
		rdr.ActiveDiscRadarRecipient = emesary.Recipient.new("ActiveDiscRadarRecipient");
		rdr.ActiveDiscRadarRecipient.radar = rdr;
		rdr.ActiveDiscRadarRecipient.Receive = func(notification) {
	        if (notification.NotificationType == "FORNotification") {
	        	#printf("DiscRadar recv: %s", notification.NotificationType);
	            #if (rdr.enabled == 1) { no, lets keep this part running, so we have fresh data when its re-enabled
	    		    rdr.vector_aicontacts_for = notification.vector;
	    		    rdr.purgeBleps();
	    		    #print("size(rdr.vector_aicontacts_for)=",size(rdr.vector_aicontacts_for));
	    	    #}
	            return emesary.Transmitter.ReceiptStatus_OK;
	        }
	        if (notification.NotificationType == "ChaffReleaseNotification") {
	    		rdr.chaffList ~= notification.vector;
	            return emesary.Transmitter.ReceiptStatus_OK;
	        }
	        return emesary.Transmitter.ReceiptStatus_NotProcessed;
	    };
		emesary.GlobalTransmitter.Register(rdr.ActiveDiscRadarRecipient);
		rdr.timer = maketimer(scanInterval, rdr, func rdr.loop());
		rdr.timerSlow = maketimer(0.75, rdr, func rdr.loopSlow());
		rdr.timerMedium = maketimer(0.25, rdr, func rdr.loopMedium());
		rdr.timerMedium.start();
		rdr.timerSlow.start();
		rdr.timer.start();
    	return rdr;
	},
	getTiltKnob: func {
		me.theKnob = antennae_knob_prop.getValue();
		if (math.abs(me.theKnob) < 0.01) {
			antennae_knob_prop.setValue(0);
			me.theKnob = 0;
		}
		return me.theKnob*60;
	},
	increaseRange: func {
		if (me["gmapper"] != nil) me.gmapper.clear();
		me.currentMode.increaseRange();
	},
	decreaseRange: func {
		if (me["gmapper"] != nil) me.gmapper.clear();
		me.currentMode.decreaseRange();
	},
	designate: func (designate_contact) {
		me.currentMode.designate(designate_contact);
	},
	designateRandom: func {
		# Use this method mostly for testing
		if (size(me.vector_aicontacts_bleps) > 0) {
			me.designate(me.vector_aicontacts_bleps[size(me.vector_aicontacts_bleps)-1]);
		}
	},
	undesignate: func {
		me.currentMode.undesignate();
	},
	getPriorityTarget: func {
		if (!me.enabled) return nil;
		return me.currentMode.getPriority();
	},
	cycleDesignate: func {
		me.currentMode.cycleDesignate();
	},
	cycleMode: func {
		me.currentModeIndex[me.rootMode] += 1;
		if (me.currentModeIndex[me.rootMode] >= size(me.mainModes[me.rootMode])) {
			me.currentModeIndex[me.rootMode] = 0;
		}
		me.newMode = me.mainModes[me.rootMode][me.currentModeIndex[me.rootMode]];
		me.newMode.setRange(me.currentMode.getRange());
		me.oldMode = me.currentMode;
		me.setCurrentMode(me.newMode, me.oldMode["priorityTarget"]);
	},
	cycleRootMode: func {
		me.rootMode += 1;
		if (me.rootMode >= size(me.mainModes)) {
			me.rootMode = 0;
		}

		me.newMode = me.mainModes[me.rootMode][me.currentModeIndex[me.rootMode]];
		#me.newMode.setRange(me.currentMode.getRange());
		me.oldMode = me.currentMode;
		me.setCurrentMode(me.newMode, me.oldMode["priorityTarget"]);
	},
	cycleAZ: func {
		if (me["gmapper"] != nil) me.gmapper.clear();
		me.clearShowScan();
		me.currentMode.cycleAZ();
	},
	cycleBars: func {
		me.currentMode.cycleBars();
		me.clearShowScan();
	},
	getDeviation: func {
		return me.currentMode.getDeviation();
	},
	setCursorDeviation: func (cursor_az) {
		return me.currentMode.setCursorDeviation(cursor_az);
	},
	getCursorDeviation: func {
		return me.currentMode.getCursorDeviation();
	},
	setCursorDistance: func (nm) {
		# Return if the cursor should be distance zeroed.
		return me.currentMode.setCursorDistance(nm);;
	},
	getCursorAltitudeLimits: func {
		if (!me.enabled) return nil;
		return me.currentMode.getCursorAltitudeLimits();
	},
	getBars: func {
		return me.currentMode.getBars();
	},
	getAzimuthRadius: func {
		return me.currentMode.getAz();
	},
	getMode: func {
		return me.currentMode.shortName;
	},
	setCurrentMode: func (new_mode, priority = nil) {
		me.olderMode = me.currentMode;
		me.currentMode = new_mode;
		new_mode.radar = me;
		#new_mode.setCursorDeviation(me.currentMode.getCursorDeviation()); # no need since submodes don't overwrite this
		new_mode.designatePriority(priority);
		if (me.olderMode != nil) me.olderMode.leaveMode();
		new_mode.enterMode();
		settimer(func me.clearShowScan(), 0.5);
	},
	setRootMode: func (mode_number, priority = nil) {
		me.rootMode = mode_number;
		if (me.rootMode >= size(me.mainModes)) {
			me.rootMode = 0;
		}

		me.newMode = me.mainModes[me.rootMode][me.currentModeIndex[me.rootMode]];
		#me.newMode.setRange(me.currentMode.getRange());
		me.oldMode = me.currentMode;
		me.setCurrentMode(me.newMode, priority);
	},
	getRange: func {
		return me.currentMode.getRange();
	},
	getCaretPosition: func {
		if (me["eulerX"] == nil or me["eulerY"] == nil) {
			return [0,0];
		} elsif (me.horizonStabilized) {
			return [me.eulerX/me.fieldOfRegardMaxAz,me.eulerY/me.fieldOfRegardMaxElev];
		} else {
			return [me.eulerX/me.fieldOfRegardMaxAz,me.eulerY/me.fieldOfRegardMaxElev];
		}
	},
	getCaretLinePosition: func {
		if (me["eulerX"] == nil or me["eulerY"] == nil) {
			return [0,0];
		} elsif (me.horizonStabilized) {
			return [me.eulerX,me.eulerY];
		} else {
			return [me.eulerX/me.fieldOfRegardMaxAz,me.eulerY/me.fieldOfRegardMaxElev];
		}
	},
	setAntennae: func (local_dir) {
		# remember to set horizonStabilized when calling this.

		# convert from coordinates to polar
		me.eulerDir = vector.Math.cartesianToEuler(local_dir);

		# Make sure if pitch is 90 or -90 that heading gets set to something sensible
		me.eulerX = me.eulerDir[0]==nil?0:geo.normdeg180(me.eulerDir[0]);
		me.eulerY = me.eulerDir[1];

		# Make array: [heading_degs, pitch_degs, heading_norm, pitch_norm], for convinience, not used atm.
		#me.positionEuler = [me.eulerX,me.eulerDir[1],me.eulerX/me.fieldOfRegardMaxAz,me.eulerDir[1]/me.fieldOfRegardMaxElev];

		# Make the antennae direction-vector be length 1.0
		me.positionDirection = vector.Math.normalize(local_dir);

		# Decompose the antennae direction-vector into seperate angles for Azimuth and Elevation
		me.posAZDeg = -90+R2D*math.acos(vector.Math.normalize(vector.Math.projVectorOnPlane([0,0,1],me.positionDirection))[1]);
		me.posElDeg = R2D*math.asin(vector.Math.normalize(vector.Math.projVectorOnPlane([0,1,0],me.positionDirection))[2]);

		# Make an array that holds: [azimuth_norm, elevation_norm, azimuth_deg, elevation_deg]
		me.positionCart = [me.posAZDeg/me.fieldOfRegardMaxAz, me.posElDeg/me.fieldOfRegardMaxElev,me.posAZDeg,me.posElDeg];

		# Note: that all these numbers can be either relative to aircraft or relative to scenery.
		# Its the modes responsibility to call this method with antennae local_dir that is either relative to
		# aircraft, or to landscape so that they match how scanFOV compares the antennae direction to target positions.
		#
		# Make sure that scanFOV() knows what coord system you are operating in. By setting me.horizonStabilized.
	},
	installMapper: func (gmapper) {
		me.gmapper = gmapper;
	},
	isEnabled: func {
		return 1;
	},
	loop: func {
		me.enabled = me.isEnabled();
		setprop("instrumentation/radar/radar-standby", !me.enabled);
		# calc dt here, so we don't get a massive dt when going from disabled to enabled:
		me.elapsed = elapsedProp.getValue();
		me.dt = me.elapsed - me.lastElapsed;
		me.lastElapsed = me.elapsed;
		if (me.enabled) {
			if (me.currentMode.painter and me.currentMode.detectAIR) {
				# We need faster updates to not lose track of oblique flying locks close by when in STT.
				me.ContactNotification.vector = [me.getPriorityTarget()];
				emesary.GlobalTransmitter.NotifyAll(me.ContactNotification);
			}

			while (me.dt > 0.001) {
				# mode tells us how to move disc and to scan
				me.dt = me.currentMode.step(me.dt);# mode already knows where in pattern we are and AZ and bars.

				# we then step to the new position, and scan for each step
				me.scanFOV();
				me.showScan();
			}

		} elsif (size(me.vector_aicontacts_bleps)) {
			# So that when radar is restarted there is not old bleps.
			me.purgeAllBleps();
		}
	},
	loopMedium: func {
		#
		# It send out what target we are Single-target-track locked onto if any so the target get RWR warning.
		# It also sends out on datalink what we are STT/SAM/TWS locked onto.
		# In addition it notifies the weapons what we have targeted.
		# Plus it sets the MP property for radar standby so others can see us on RWR.
		if (me.enabled) {
			me.focus = me.getPriorityTarget();
			if (me.focus != nil and me.focus.callsign != "") {
				if (me.currentMode.painter) sttSend.setValue(left(md5(me.focus.callsign), 4));
				else sttSend.setValue("");
				if (steerpoints.sending == nil) {
			        datalink.send_data({"contacts":[{"callsign":me.focus.callsign,"iff":0}]});
			    }
			} else {
				sttSend.setValue("");
				if (steerpoints.sending == nil) {
		            datalink.clear_data();
		        }
			}
			armament.contact = me.focus;
			stbySend.setIntValue(0);
		} else {
			armament.contact = nil;
			sttSend.setValue("");
			stbySend.setIntValue(1);
			if (steerpoints.sending == nil) {
	            datalink.clear_data();
	        }
		}

		me.debug = getprop("debug-radar/debug-main");
	},
	loopSlow: func {
		#
		# Here we ask the NoseRadar for a slice of the sky once in a while.
		#
		if (me.enabled and !(me.currentMode.painter and me.currentMode.detectAIR)) {
			emesary.GlobalTransmitter.NotifyAll(me.SliceNotification.slice(self.getPitch(), self.getHeading(), math.max(-me.fieldOfRegardMinElev, me.fieldOfRegardMaxElev)*1.414, me.fieldOfRegardMaxAz*1.414, me.getRange()*NM2M, !me.currentMode.detectAIR, !me.currentMode.detectSURFACE, !me.currentMode.detectMARINE));
		}
	},
	scanFOV: func {
		#
		# Here we test for IFF and test the radar beam against targets to see if the radar picks them up.
		#
		# Note that this can happen in aircraft coords (ACM modes) or in landscape coords (the other modes).
		me.doIFF = getprop("instrumentation/radar/iff");
    	setprop("instrumentation/radar/iff",0);
    	if (me.doIFF) iff.last_interogate = systime();
    	if (me["gmapper"] != nil) me.gmapper.scanGM(me.eulerX, me.eulerY, me.instantVertFoVradius, me.instantFoVradius,
    		 me.currentMode.bars == 1 or (me.currentMode.bars == 4 and me.currentMode["nextPatternNode"] == 0) or (me.currentMode.bars == 3 and me.currentMode["nextPatternNode"] == 7) or (me.currentMode.bars == 2 and me.currentMode["nextPatternNode"] == 1),
    		 me.currentMode.bars == 1 or (me.currentMode.bars == 4 and me.currentMode["nextPatternNode"] == 2) or (me.currentMode.bars == 3 and me.currentMode["nextPatternNode"] == 3) or (me.currentMode.bars == 2 and me.currentMode["nextPatternNode"] == 3));# The last two parameter is hack

    	# test for passive ECM (chaff)
		#
		me.closestChaff = 1000000;# meters
		if (size(me.chaffList)) {
			if (me.horizonStabilized) {
				me.globalAntennaeDir = vector.Math.yawVector(-self.getHeading(), me.positionDirection);
			} else {
				me.globalAntennaeDir = vector.Math.rollPitchYawVector(self.getRoll(), self.getPitch(), -self.getHeading(), me.positionDirection);
			}

			foreach (me.chaff ; me.chaffList) {
				if (rand() < me.chaffFilter or me.chaff.meters < 10000+10000*rand()) continue;# some chaff are filtered out.
				me.globalToTarget = vector.Math.pitchYawVector(me.chaff.pitch, -me.chaff.bearing, [1,0,0]);

				# Degrees from center of radar beam to center of chaff cloud
				me.beamDeviation = vector.Math.angleBetweenVectors(me.globalAntennaeDir, me.globalToTarget);

				if (me.beamDeviation < me.instantFoVradius) {
					if (me.chaff.meters < me.closestChaff) {
						me.closestChaff = me.chaff.meters;
					}
					me.registerChaff(me.chaff);# for displays
					#print("REGISTER CHAFF");
				}# elsif(me.debug > -1) {
					# This is too detailed for most debugging, remove later
				#	setprop("debug-radar/main-beam-deviation-chaff", me.beamDeviation);
				#}
			}
		}

    	me.testedPrio = 0;
		foreach(contact ; me.vector_aicontacts_for) {
			if (me.doIFF == 1) {
	            me.iffr = iff.interrogate(contact.prop);
	            if (me.iffr) {
	                contact.iff = me.elapsed;
	            } else {
	                contact.iff = -me.elapsed;
	            }
	        }
			if (me.elapsed - contact.getLastBlepTime() < me.currentMode.minimumTimePerReturn) {
				if(me.debug > 1 and me.currentMode.painter and contact == me.getPriorityTarget()) {
					me.testedPrio = 1;
				}
				continue;# To prevent double detecting in overlapping beams
			}

			me.dev = contact.getDeviationStored();

			if (me.horizonStabilized) {
				# ignore roll and pitch

				# Vector that points to target in radar coordinates as if aircraft it was not rolled or pitched.
				me.globalToTarget = vector.Math.eulerToCartesian3X(-me.dev.bearing,me.dev.elevationGlobal,0);

				# Vector that points to target in radar coordinates as if aircraft it was not yawed, rolled or pitched.
				me.localToTarget = vector.Math.yawVector(self.getHeading(), me.globalToTarget);
			} else {
				# Vector that points to target in local radar coordinates.
				me.localToTarget = vector.Math.eulerToCartesian3X(-me.dev.azimuthLocal,me.dev.elevationLocal,0);
			}

			# Degrees from center of radar beam to target, note that positionDirection must match the coord system defined by horizonStabilized.
			me.beamDeviation = vector.Math.angleBetweenVectors(me.positionDirection, me.localToTarget);

			if(me.debug > 1 and me.currentMode.painter and contact == me.getPriorityTarget()) {
				# This is too detailed for most debugging, remove later
				setprop("debug-radar/main-beam-deviation", me.beamDeviation);
				me.testedPrio = 1;
			}
			if (me.beamDeviation < me.instantFoVradius and (me.dev.rangeDirect_m < me.closestChaff or rand() < me.chaffFilter) ) {#  and (me.closureReject == -1 or me.dev.closureSpeed > me.closureReject)
				# TODO: Refine the chaff conditional (ALOT)
				me.registerBlep(contact, me.dev, me.currentMode.painter, me.currentMode.pulse);
				#print("REGISTER BLEP");

				# Return here, so that each instant FoV max gets 1 target:
				# TODO: refine by testing angle between contacts seen in this FoV
				break;
			}
		}

		if(me.debug > 1 and me.currentMode.painter and !me.testedPrio) {
			setprop("debug-radar/main-beam-deviation", "--unseen-lock--");
		}
	},
	registerBlep: func (contact, dev, stt, doppler = 1) {
		if (!contact.isVisible()) return 0;
		if (doppler) {
			if (contact.isHiddenFromDoppler()) {
				return 0;
			}
			if (math.abs(dev.closureSpeed) < me.currentMode.minClosure) {
				return 0;
			}
		}

		me.maxDistVisible = me.currentMode.rcsFactor * me.targetRCSSignal(self.getCoord(), dev.coord, contact.model, dev.heading, dev.pitch, dev.roll,me.rcsRefDistance*NM2M,me.rcsRefValue);

		if (me.maxDistVisible > dev.rangeDirect_m) {
			me.extInfo = me.currentMode.getSearchInfo(contact);# if the scan gives heading info etc..

			if (me.extInfo == nil) {
				return 0;
			}
			contact.blep(me.elapsed, me.extInfo, me.maxDistVisible, stt);
			if (!me.containsVectorContact(me.vector_aicontacts_bleps, contact)) {
				append(me.vector_aicontacts_bleps, contact);
			}
			return 1;
		}
		return 0;
	},
	registerChaff: func (chaff) {
		chaff.seenTime = me.elapsed;
		if (!me.containsVector(me.chaffSeenList, chaff)) {
			append(me.chaffSeenList, chaff);
		}
	},
	purgeBleps: func {
		#ok, lets clean up old bleps:
		me.vector_aicontacts_bleps_tmp = [];
		me.elapsed = elapsedProp.getValue();
		foreach(contact ; me.vector_aicontacts_bleps) {
			me.bleps_cleaned = [];
			foreach (me.blep;contact.getBleps()) {
				if (me.elapsed - me.blep.getBlepTime() < me.currentMode.timeToFadeBleps) {
					append(me.bleps_cleaned, me.blep);
				}
			}
			contact.setBleps(me.bleps_cleaned);
			if (size(me.bleps_cleaned)) {
				append(me.vector_aicontacts_bleps_tmp, contact);
				me.currentMode.testContact(contact);# TODO: do this smarter
			} else {
				me.currentMode.prunedContact(contact);
			}
		}
		#print("Purged ", size(me.vector_aicontacts_bleps) - size(me.vector_aicontacts_bleps_tmp), " bleps   remains:",size(me.vector_aicontacts_bleps_tmp), " orig ",size(me.vector_aicontacts_bleps));
		me.vector_aicontacts_bleps = me.vector_aicontacts_bleps_tmp;

		#lets purge the old chaff also, both seen and unseen
		me.wnd = wndprop.getValue();
		me.chaffLifetime = math.max(0, me.wnd==0?25:25*(1-me.wnd/50));
		me.chaffList_tmp = [];
		foreach(me.evilchaff ; me.chaffList) {
			if (me.elapsed - me.evilchaff.releaseTime < me.chaffLifetime) {
				append(me.chaffList_tmp, me.evilchaff);
			}
		}
		me.chaffList = me.chaffList_tmp;

		me.chaffSeenList_tmp = [];
		foreach(me.evilchaff ; me.chaffSeenList) {
			if (me.elapsed - me.evilchaff.releaseTime < me.chaffLifetime or me.elapsed - me.evilchaff.seenTime < me.timeToKeepBleps) {
				append(me.chaffSeenList_tmp, me.evilchaff);
			}
		}
		me.chaffSeenList = me.chaffSeenList_tmp;
	},
	purgeAllBleps: func {
		#ok, lets delete all bleps:
		foreach(contact ; me.vector_aicontacts_bleps) {
			contact.setBleps([]);
			me.currentMode.prunedContact(contact);
		}
		me.vector_aicontacts_bleps = [];
		me.chaffSeenList = [];
	},
	targetRCSSignal: func(aircraftCoord, targetCoord, targetModel, targetHeading, targetPitch, targetRoll, myRadarDistance_m = 74000, myRadarStrength_rcs = 3.2) {
		#
		# test method. Belongs in rcs.nas.
		#
	    me.target_front_rcs = nil;
	    if ( contains(rcs.rcs_oprf_database,targetModel) ) {
	        me.target_front_rcs = rcs.rcs_oprf_database[targetModel];
	    } elsif ( contains(rcs.rcs_database,targetModel) ) {
	        me.target_front_rcs = rcs.rcs_database[targetModel];
	    } else {
	        # GA/Commercial return most likely
	        me.target_front_rcs = rcs.rcs_oprf_database["default"];
	    }
	    me.target_rcs = rcs.getRCS(targetCoord, targetHeading, targetPitch, targetRoll, aircraftCoord, me.target_front_rcs);

	    # standard formula
	    return myRadarDistance_m/math.pow(myRadarStrength_rcs/me.target_rcs, 1/4);
	},
	getActiveBleps: func {
		return me.vector_aicontacts_bleps;
	},
	getActiveChaff: func {
		return me.chaffSeenList;
	},
	showScan: func {
		if (me.debug > 0) {
			if (me["canvas2"] == nil) {
	            me.canvas2 = canvas.Window.new([512,512],"dialog").set('title',"Scan").getCanvas(1);
				me.canvas_root2 = me.canvas2.createGroup().setTranslation(256,256);
				me.canvas2.setColorBackground(0.25,0.25,1);
			}

			if (me.elapsed - me.currentMode.lastFrameStart < 0.1) {
				me.clearShowScan();
			}
			me.canvas_root2.createChild("path")
				.setTranslation(256*me.eulerX/60, -256*me.eulerY/60)
				.moveTo(0, 256*me.instantFoVradius/60)
				.lineTo(0, -256*me.instantFoVradius/60)
				.setColor(1,1,1);
		}
	},
	clearShowScan: func {
		if (me["canvas2"] == nil or me.debug < 1) return;
		me.canvas_root2.removeAllChildren();
		if (me.horizonStabilized) {
			me.canvas_root2.createChild("path")
				.moveTo(-250, 0)
				.lineTo(250, 0)
				.setColor(1,1,0)
				.setStrokeLineWidth(4);
		} else {
			me.canvas_root2.createChild("path")
				.moveTo(256*-5/60, 256*-1.5/60)
				.lineTo(256*5/60, 256*-1.5/60)
				.lineTo(256*5/60,  256*15/60)
				.lineTo(256*-5/60,  256*15/60)
				.lineTo(256*-5/60, 256*-1.5/60)
				.setColor(1,1,0)
				.setStrokeLineWidth(4);
		}
	},
	containsVector: func (vec, item) {
		foreach(test; vec) {
			if (test == item) {
				return 1;
			}
		}
		return 0;
	},

	containsVectorContact: func (vec, item) {
		foreach(test; vec) {
			if (test.equals(item)) {
				return 1;
			}
		}
		return 0;
	},

	vectorIndex: func (vec, item) {
		me.i = 0;
		foreach(test; vec) {
			if (test == item) {
				return me.i;
			}
			me.i += 1;
		}
		return -1;
	},
	del: func {
        emesary.GlobalTransmitter.DeRegister(me.ActiveDiscRadarRecipient);
    },
};










var SPOT_SCAN = -1; # must be -1





#  ██████   █████  ██████   █████  ██████      ███    ███  ██████  ██████  ███████
#  ██   ██ ██   ██ ██   ██ ██   ██ ██   ██     ████  ████ ██    ██ ██   ██ ██
#  ██████  ███████ ██   ██ ███████ ██████      ██ ████ ██ ██    ██ ██   ██ █████
#  ██   ██ ██   ██ ██   ██ ██   ██ ██   ██     ██  ██  ██ ██    ██ ██   ██ ██
#  ██   ██ ██   ██ ██████  ██   ██ ██   ██     ██      ██  ██████  ██████  ███████
#
#
var RadarMode = {
	#
	# Subclass and modify as needed.
	#
	radar: nil,
	range: 40,
	minRange: 5,
	maxRange: 160,
	az: 60,
	bars: 1,
	azimuthTilt: 0,# modes set these depending on where they want the pattern to be centered.
	elevationTilt: 0,
	barHeight: 0.80,# multiple of instantFoVradius
	barPattern:  [ [[-1,0],[1,0]] ],     # The second is multitude of instantFoVradius, the first is multitudes of me.az
	barPatternMin: [0],
	barPatternMax: [0],
	nextPatternNode: 0,
	scanPriorityEveryFrame: 0,# Related to SPOT_SCAN.
	timeToFadeBleps: 13,
	rootName: "Base",
	shortName: "",
	longName: "",
	superMode: nil,
	minimumTimePerReturn: 0.5,
	rcsFactor: 0.9,
	lastFrameStart: -1,
	lastFrameDuration: 5,
	detectAIR: 1,
	detectSURFACE: 0,
	detectMARINE: 0,
	pulse: DOPPLER, # MONO or DOPPLER
	minClosure: 0, # kt
	cursorAz: 0,
	cursorNm: 20,
	upperAngle: 10,
	lowerAngle: 10,
	painter: 0, # if the mode when having a priority target will produce a hard lock on target.
	mapper: 0,
	discSpeed_dps: 1,# current disc speed. Must never be zero.
	setRange: func (range) {
		me.testMulti = me.maxRange/range;
		if (int(me.testMulti) != me.testMulti) {
			# max range is not dividable by range, so we don't change range
			return 0;
		}
		me.range = math.min(me.maxRange, range);
		me.range = math.max(me.minRange, me.range);
		return range == me.range;
	},
	getRange: func {
		return me.range;
	},
	_increaseRange: func {
		me.range*=2;
		if (me.range>me.maxRange) {
			me.range*=0.5;
			return 0;
		}
		return 1;
	},
	_decreaseRange: func {
		me.range *= 0.5;
		if (me.range < me.minRange) {
			me.range *= 2;
			return 0;
		}
		return 1;
	},
	getDeviation: func {
		# how much the pattern is deviated from straight ahead in azimuth
		return me.azimuthTilt;
	},
	getBars: func {
		return me.bars;
	},
	getAz: func {
		return me.az;
	},
	constrainAz: func () {
		# Convinience method that the modes can use.
		if (me.az == me.radar.fieldOfRegardMaxAz) {
			me.azimuthTilt = 0;
		} elsif (me.azimuthTilt > me.radar.fieldOfRegardMaxAz-me.az) {
			me.azimuthTilt = me.radar.fieldOfRegardMaxAz-me.az;
		} elsif (me.azimuthTilt < -me.radar.fieldOfRegardMaxAz+me.az) {
			me.azimuthTilt = -me.radar.fieldOfRegardMaxAz+me.az;
		}
	},
	getPriority: func {
		return me["priorityTarget"];
	},
	computePattern: func {
		# Translate the normalized pattern nodes into degrees. Since me.az or maybe me.bars have tendency to change rapidly
		# We do this every step. Its fast anyway.
		me.currentPattern = [];
		foreach (me.eulerNorm ; me.barPattern[me.bars-1]) {
			me.patternNode = [me.eulerNorm[0]*me.az, me.eulerNorm[1]*me.radar.instantFoVradius*me.barHeight];
			append(me.currentPattern, me.patternNode);
		}
		return me.currentPattern;
	},
	step: func (dt) {
		me.radar.horizonStabilized = 1;# Might be unset inside preStep()

		# Individual modes override this method and get ready for the step.
		# Inside this they typically set 'azimuthTilt' and 'elevationTilt' for moving the pattern around.
		me.preStep();

		# Lets figure out the desired antennae tilts
	 	me.azimuthTiltIntern = me.azimuthTilt;
	 	me.elevationTiltIntern = me.elevationTilt;
		if (me.nextPatternNode == SPOT_SCAN and me.priorityTarget != nil) {
			# We never do spot scans in ACM modes so no check for horizonStabilized here.
			me.lastBlep = me.priorityTarget.getLastBlep();
			if (me.lastBlep != nil) {
				me.azimuthTiltIntern = me.lastBlep.getAZDeviation();
				me.elevationTiltIntern = me.lastBlep.getElev();
			} else {
				me.priorityTarget = nil;
				me.undesignate();
				me.nextPatternNode == 0;
			}
		} elsif (me.nextPatternNode == SPOT_SCAN) {
			# We cannot do spot scan on stuff we cannot see, reverting back to pattern
			me.nextPatternNode = 0;
		}

		# now lets check where we want to move the disc to
		me.currentPattern      = me.computePattern();
		me.targetAzimuthTilt   = me.azimuthTiltIntern+(me.nextPatternNode!=SPOT_SCAN?me.currentPattern[me.nextPatternNode][0]:0);
		me.targetElevationTilt = me.elevationTiltIntern+(me.nextPatternNode!=SPOT_SCAN?me.currentPattern[me.nextPatternNode][1]:0);

		# The pattern min/max pitch when not tilted.
		me.min = me.barPatternMin[me.bars-1]*me.barHeight*me.radar.instantFoVradius;
		me.max = me.barPatternMax[me.bars-1]*me.barHeight*me.radar.instantFoVradius;

		# We check if radar gimbal mount can turn enough.
		me.gimbalInBounds = 1;
		if (me.radar.horizonStabilized) {
			# figure out if we reach the gimbal limit
	 		me.actualMin = self.getPitch()+me.radar.fieldOfRegardMinElev;
	 		me.actualMax = self.getPitch()+me.radar.fieldOfRegardMaxElev;
	 		if (me.targetElevationTilt < me.actualMin) {
	 			me.gimbalInBounds = 0;
	 		} elsif (me.targetElevationTilt > me.actualMax) {
	 			me.gimbalInBounds = 0;
	 		}
 		}
 		if (!me.gimbalInBounds) {
 			# Don't move the antennae if it cannot reach whats requested.
 			# This basically stop the radar from working while still not on standby
 			# until better attitude is reached.
 			#
 			# It used to attempt to scan in edge of FoR but thats not really helpful to a pilot.
 			# If need to scan while extreme attitudes then the are specific modes for that (in some aircraft).
 			me.radar.setAntennae(me.radar.positionDirection);
 			#print("db-Out of gimbal bounds");
	 		return 0;
	 	}

	 	# For help with cursor limits we need to compute these
		if (me.radar.horizonStabilized and me.gimbalInBounds) {
			me.lowerAngle = me.min+me.elevationTiltIntern;
			me.upperAngle = me.max+me.elevationTiltIntern;
		} else {
			me.lowerAngle = 0;
			me.upperAngle = 0;
		}

	 	# Lets get a status for where we are in relation to where we are going
		me.targetDir = vector.Math.pitchYawVector(me.targetElevationTilt, -me.targetAzimuthTilt, [1,0,0]);# A vector for where we want the disc to go
		me.angleToNextNode = vector.Math.angleBetweenVectors(me.radar.positionDirection, me.targetDir);# Lets test how far from the target tilts we are.

		# Move the disc
		if (me.angleToNextNode < me.radar.instantFoVradius) {
			# We have reached our target
			me.radar.setAntennae(me.targetDir);
			me.nextPatternNode += 1;
			if (me.nextPatternNode >= size(me.currentPattern)) {
				me.nextPatternNode = (me.scanPriorityEveryFrame and me.priorityTarget!=nil)?SPOT_SCAN:0;
				me.frameCompleted();
			}
			#print("db-node:", me.nextPatternNode);
			# Now the antennae has been moved and we return how much leftover dt there is to the main radar.
			return dt-me.angleToNextNode/me.discSpeed_dps;# Since we move disc seperately in axes, this is not strictly correct, but close enough.
		}

		# Lets move each axis of the radar seperate, as most radars likely has 2 joints anyway.
		me.maxMove = math.min(me.radar.instantFoVradius*overlapHorizontal, me.discSpeed_dps*dt);# 1.75 instead of 2 is because the FoV is round so we overlap em a bit

		# Azimuth
		me.distance_deg = me.targetAzimuthTilt - me.radar.eulerX;
		if (me.distance_deg >= 0) {
			me.moveX =  math.min(me.maxMove, me.distance_deg);
		} else {
			me.moveX = math.max(-me.maxMove, me.distance_deg);
		}
		me.newX = me.radar.eulerX + me.moveX;

		# Elevation
		me.distance_deg = me.targetElevationTilt - me.radar.eulerY;
		if (me.distance_deg >= 0) {
			me.moveY =  math.min(me.maxMove, me.distance_deg);
		} else {
			me.moveY =  math.max(-me.maxMove, me.distance_deg);
		}
		me.newY = me.radar.eulerY + me.moveY;

		# Convert the angles to a vector and set the new antennae position
		me.newPos = vector.Math.pitchYawVector(me.newY, -me.newX, [1,0,0]);
		me.radar.setAntennae(me.newPos);

		# As the two joins move at the same time, we find out which moved the most
		me.movedMax = math.max(math.abs(me.moveX), math.abs(me.moveY));
		if (me.movedMax == 0) {
			# This should really not happen, we return 0 to make sure the while loop don't get infinite.
			print("me.movedMax == 0");
			return 0;
		}
		if (me.movedMax > me.discSpeed_dps) {
			print("me.movedMax > me.discSpeed_dps");
			return 0;
		}
		return dt-me.movedMax/me.discSpeed_dps;
	},
	frameCompleted: func {
		if (me.lastFrameStart != -1) {
			me.lastFrameDuration = me.radar.elapsed - me.lastFrameStart;
		}
		me.lastFrameStart = me.radar.elapsed;
	},
	setCursorDeviation: func (cursor_az) {
		me.cursorAz = cursor_az;
	},
	getCursorDeviation: func {
		return me.cursorAz;
	},
	setCursorDistance: func (nm) {
		# Return if the cursor should be distance zeroed.
		return 0;
	},
	getCursorAltitudeLimits: func {
		# Used in F-16 with two numbers next to cursor that indicates min/max for radar pattern in altitude above sealevel.
		# It needs: me.lowerAngle, me.upperAngle and me.cursorNm
		me.vectorToDist = [math.cos(me.upperAngle*D2R), 0, math.sin(me.upperAngle*D2R)];
		me.selfC = self.getCoord();
		me.geo = vector.Math.vectorToGeoVector(me.vectorToDist, me.selfC);
		me.geo = vector.Math.product(me.cursorNm*NM2M, vector.Math.normalize(me.geo.vector));
		me.up = geo.Coord.new();
		me.up.set_xyz(me.selfC.x()+me.geo[0],me.selfC.y()+me.geo[1],me.selfC.z()+me.geo[2]);
		me.vectorToDist = [math.cos(me.lowerAngle*D2R), 0, math.sin(me.lowerAngle*D2R)];
		me.geo = vector.Math.vectorToGeoVector(me.vectorToDist, me.selfC);
		me.geo = vector.Math.product(me.cursorNm*NM2M, vector.Math.normalize(me.geo.vector));
		me.down = geo.Coord.new();
		me.down.set_xyz(me.selfC.x()+me.geo[0],me.selfC.y()+me.geo[1],me.selfC.z()+me.geo[2]);
		return [me.up.alt()*M2FT, me.down.alt()*M2FT];
	},
	leaveMode: func {
		# Warning: In this method do not set anything on me.radar only on me.
		me.lastFrameStart = -1;
	},
	enterMode: func {
	},
	designatePriority: func (contact) {},
	cycleDesignate: func {},
	testContact: func (contact) {},
	prunedContact: func (c) {
		if (c.equalsFast(me["priorityTarget"])) {
			me.priorityTarget = nil;
		}
		if (c.equalsFast(me["priorityTarget2"])) {
			me.priorityTarget2 = nil;
		}
	},
};#                                    END Radar Mode class






#  ██████   █████  ████████  █████  ██      ██ ███    ██ ██   ██ 
#  ██   ██ ██   ██    ██    ██   ██ ██      ██ ████   ██ ██  ██  
#  ██   ██ ███████    ██    ███████ ██      ██ ██ ██  ██ █████  
#  ██   ██ ██   ██    ██    ██   ██ ██      ██ ██  ██ ██ ██  ██ 
#  ██████  ██   ██    ██    ██   ██ ███████ ██ ██   ████ ██   ██ 
#                                                                
#
DatalinkRadar = {
	# I check the sky 360 deg for anything on datalink
	#
	# I will set 'blue' and 'blueIndex' on contacts.
	# blue==1: On our datalink
	# blue==2: Targeted by someone on our datalink
	#
	# Direct line of sight required for ~1000MHz signal.
	#
	# This class is only semi generic!
	new: func (rate, max_dist_fighter_nm, max_dist_station_nm) {
		var dlnk = {parents: [DatalinkRadar, Radar]};

		dlnk.max_dist_fighter_nm = max_dist_fighter_nm;
		dlnk.max_dist_station_nm = max_dist_station_nm;

		datalink.can_transmit = func(callsign, mp_prop, mp_index) {
		    dlnk.contactSender = callsignToContact.get(callsign);
		    if (dlnk.contactSender == nil) return 0;
		    if (!dlnk.contactSender.isValid()) return 0;
		    if (!dlnk.contactSender.isVisible()) return 0;

		    dlnk.isContactStation = isKnownSurface(dlnk.contactSender.getModel()) or isKnownShip(dlnk.contactSender.getModel()) or isKnownAwacs(dlnk.contactSender.getModel());
		    dlnk.max_dist_nm = dlnk.isContactStation?dlnk.max_dist_station_nm:dlnk.max_dist_fighter_nm;
		    
		    return dlnk.contactSender.get_range() < dlnk.max_dist_nm;
		}

		
		dlnk.index = 0;
		dlnk.vector_aicontacts = [];
		dlnk.vector_aicontacts_for = [];
		dlnk.timer          = maketimer(rate, dlnk, func dlnk.scan());

		dlnk.DatalinkRadarRecipient = emesary.Recipient.new("DatalinkRadarRecipient");
		dlnk.DatalinkRadarRecipient.radar = dlnk;
		dlnk.DatalinkRadarRecipient.Receive = func(notification) {
	        if (notification.NotificationType == "AINotification") {
	        	#printf("DLNKRadar recv: %s", notification.NotificationType);
	        	#printf("DLNKRadar notified of %d contacts", size(notification.vector));
    		    me.radar.vector_aicontacts = notification.vector;
    		    me.radar.index = 0;
	            return emesary.Transmitter.ReceiptStatus_OK;
	        }
	        return emesary.Transmitter.ReceiptStatus_NotProcessed;
	    };
		emesary.GlobalTransmitter.Register(dlnk.DatalinkRadarRecipient);
		dlnk.DatalinkNotification = VectorNotification.new("DatalinkNotification");
		dlnk.DatalinkNotification.updateV(dlnk.vector_aicontacts_for);
		dlnk.timer.start();
		return dlnk;
	},

	scan: func () {
		if (!me.enabled) return;

		#this loop is really fast. But we only check 1 contact per call
		if (me.index >= size(me.vector_aicontacts)) {
			# will happen if there is no contacts or if contact(s) went away
			me.index = 0;
			return;
		}
		me.contact = me.vector_aicontacts[me.index];
		me.wasBlue = me.contact["blue"];
		me.cs = me.contact.get_Callsign();
		if (me.wasBlue == nil) me.wasBlue = 0;

		if (!me.contact.isValid()) {
			me.contact.blue = 0;
			if (me.wasBlue > 0) {
				#print(me.cs," is invalid and purged from Datalink");
				me.new_vector_aicontacts_for = [];
				foreach (me.c ; me.vector_aicontacts_for) {
					if (!me.c.equals(me.contact) and !me.c.equalsFast(me.contact)) {
						append(me.new_vector_aicontacts_for, me.c);
					}
				}
				me.vector_aicontacts_for = me.new_vector_aicontacts_for;
			}
		} else {

	        
	        if (!me.contact.isValid()) {
	        	me.lnk = nil;
	        } else {
	        	me.lnk = datalink.get_data(damage.processCallsign(me.cs));
	        }
	        
	        if (me.lnk != nil and me.lnk.on_link() == 1) {
	            me.blue = 1;
	            me.blueIndex = me.lnk.index()+1;
	        } elsif (me.cs == getprop("link16/wingman-4")) { # Hack that the F16 need. Just ignore it, as nil wont cause expection.
	            me.blue = 1;
	            me.blueIndex = 0;
	        } else {
	        	me.blue = 0;
	            me.blueIndex = -1;
	        }
	        if (!me.blue and me.lnk != nil and me.lnk.tracked() == 1) {
	        	me.dl_idx = me.lnk.tracked_by_index();
	        	if (me.dl_idx != nil and me.dl_idx > -1) {
		            me.blue = 2;
		            me.blueIndex = me.dl_idx+1;
			    }
	        }

	        me.contact.blue = me.blue;
	        if (me.blue > 0) {
	        	me.contact.blueIndex = me.blueIndex;
				if (!AirborneRadar.containsVectorContact(me.vector_aicontacts_for, me.contact)) {
					append(me.vector_aicontacts_for, me.contact);
					emesary.GlobalTransmitter.NotifyAll(me.DatalinkNotification.updateV(me.vector_aicontacts_for));
				}
			} elsif (me.wasBlue > 0) {
				me.new_vector_aicontacts_for = [];
				foreach (me.c ; me.vector_aicontacts_for) {
					if (!me.c.equals(me.contact) and !me.c.equalsFast(me.contact)) {
						append(me.new_vector_aicontacts_for, me.c);
					}
				}
				me.vector_aicontacts_for = me.new_vector_aicontacts_for;
			}
		}
		me.index += 1;
        if (me.index > size(me.vector_aicontacts)-1) {
        	me.index = 0;

        	# Lets not keep contacts no longer in our scene
        	me.new_vector_aicontacts_for = [];
			foreach (me.c ; me.vector_aicontacts_for) {
				if (AirborneRadar.containsVectorContact(me.vector_aicontacts, me.c)) {
					append(me.new_vector_aicontacts_for, me.c);
				}
			}
			me.vector_aicontacts_for = me.new_vector_aicontacts_for;

        	emesary.GlobalTransmitter.NotifyAll(me.DatalinkNotification.updateV(me.vector_aicontacts_for));
        }
	},
	del: func {
        emesary.GlobalTransmitter.DeRegister(me.DatalinkRadarRecipient);
    },
};










########################### BEGIN NON-GENERIC CLASSES ##########################






var APY1 = {
	#
	# 
	#
	instantFoVradius: 8.5,#average of horiz/vert radius
	rcsRefDistance: 325,
	rcsRefValue: 63,
	targetHistory: 3,
	fieldOfRegardMaxAz: 180,
	fieldOfRegardMaxElev: 15,
	fieldOfRegardMinElev: 15,
	isEnabled: func {
		var working = getprop("instrumentation/radar/knob") and !getprop("/fdm/jsbsim/gear/unit[0]/WOW") and getprop("instrumentation/radar/serviceable");
		setprop("instrumentation/mptcas/on", working);
		return working;
	},
};






#  ███████ ███████  █████  ██████   ██████ ██   ██     ███    ███  ██████  ██████  ███████ 
#  ██      ██      ██   ██ ██   ██ ██      ██   ██     ████  ████ ██    ██ ██   ██ ██      
#  ███████ █████   ███████ ██████  ██      ███████     ██ ████ ██ ██    ██ ██   ██ █████   
#       ██ ██      ██   ██ ██   ██ ██      ██   ██     ██  ██  ██ ██    ██ ██   ██ ██      
#  ███████ ███████ ██   ██ ██   ██  ██████ ██   ██     ██      ██  ██████  ██████  ███████ 
#                                                                                          
#                                                                                          
var defaultTilt = 0;
var SearchMode = {
	radar: nil,
	shortName: "RWS",
	longName: "Range While Search",
	superMode: nil,
	subMode: nil,
	range: 200,
	lowering: 0,
	maxRange: 25,
	maxRange: 400,
	azimuthTilt: defaultTilt,
	discSpeed_dps: 36,# real scan rate for E-3
	rcsFactor: 1,
	priorityTarget: nil,
	priorityTarget2: nil,
	new: func (radar = nil) {
		var mode = {parents: [SearchMode, RadarMode]};
		mode.radar = radar;
		return mode;
	},
	designate: func (designate_contact) {
		me.priorityTarget = designate_contact;
	},
	undesignate: func {
		me.priorityTarget = nil;
	},
	designate2: func (designate_contact) {
		me.priorityTarget2 = designate_contact;
	},
	undesignate2: func {
		me.priorityTarget2 = nil;
	},
	designatePriority: func (contact) {
		me.designate(contact);
	},
	cycleBars: func {
		me.bars += 1;
		if (me.bars == 3) me.bars = 4;# 3 is only for TWS
		elsif (me.bars == 5) me.bars = 1;
		me.nextPatternNode = 0;
	},
	preStep: func {
		me.radar.tiltOverride = 1;
	},
	step: func (dt) {
		# Lets simulate it keeps spinning horizontally, and after each round it increases its elevation.

		me.radar.horizonStabilized = 1;# Might be unset inside preStep()
		me.preStep();

		me.maxMove = -math.min(me.radar.instantFoVradius*1.25, me.discSpeed_dps*dt);# 1.25 is because the FoV is round so we overlap em a bit
		me.currentPos = me.radar.positionDirection;
		if (!me.lowering) {
			me.newPos = vector.Math.rotateVectorAroundVector(me.currentPos, [0,0,1], me.maxMove);
		} else {
			me.newPos = vector.Math.rotateVectorTowardsVector(me.currentPos, me.localDir, me.maxMove);
			me.angleToNextNode = vector.Math.angleBetweenVectors(me.currentPos, me.localDir);
			if (me.angleToNextNode < me.maxMove) {
				me.lowering = 0;
				me.newPos = me.localDir;
			}
		}
		me.radar.setAntennae(me.newPos);
		if (me.currentPos[1] > 0 and me.newPos[1] <= 0) {
			# a whole round has been completed
			me.frameCompleted();
		}
		return dt+me.maxMove/me.discSpeed_dps;# The 0.001 is for presicion errors.
	},
	frameCompleted: func {
		#print("frame ",me.radar.elapsed-me.lastFrameStart);
		if (me.lastFrameStart != -1) {
			me.lastFrameDuration = me.radar.elapsed - me.lastFrameStart;
			me.timeToKeepBleps = me.radar.targetHistory*me.lastFrameDuration;
		}
		me.lastFrameStart = me.radar.elapsed;

		#me.azimuthTilt += 2*me.radar.instantFoVradius*me.barHeight;
		#if (me.azimuthTilt > me.radar.fieldOfRegardMaxElev) {
		#	me.azimuthTilt = defaultTilt;
		#}

		# we just need the elevation here
		me.localDir = vector.Math.pitchYawVector(me.azimuthTilt, 0, [1,0,0]);
		#me.lowering = 1;
		#me.radar.setAntennae(me.localDir);
	},
	increaseRange: func {
		me._increaseRange();
	},
	decreaseRange: func {
		me._decreaseRange();
	},
	setRange: func (range) {
		me.range = math.min(me.maxRange, range);
		me.range = math.max(me.minRange, me.range);
		return range == me.range;
	},
	getSearchInfo: func (contact) {
		# searchInfo:               dist, groundtrack, deviations, speed, closing-rate, altitude
		me.tst = contact==me.priorityTarget or contact==me.priorityTarget2;
		return [1,me.tst,1,me.tst,me.tst,1];
	},
};












#   ██████  ██     ██ ██████ 
#   ██   ██ ██     ██ ██   ██ 
#   ██████  ██  █  ██ ██████  
#   ██   ██ ██ ███ ██ ██   ██ 
#   ██   ██  ███ ███  ██   ██ 
#                                                           
#

var noRadarList = {
	# These have no radar
	depot:nil, point:nil, struct:nil, rig:nil, truck:nil, hunter:nil,
	"alphajet":nil, "jaguar":nil, "Jaguar-GR3":nil, "A-10-modelB":nil, "Jaguar-GR1":nil, "A-10-model":nil, "A-10":nil,
};

var RWR = {
	# inherits from Radar
	# will check radar/transponder and ground occlusion.
	# will sort according to threat level
	new: func () {
		var rr = {parents: [RWR, Radar]};

		rr.vector_aicontacts = [];
		rr.vector_aicontacts_threats = [];
		#rr.timer          = maketimer(2, rr, func rr.scan());

		rr.RWRRecipient = emesary.Recipient.new("RWRRecipient");
		rr.RWRRecipient.radar = rr;
		rr.RWRRecipient.Receive = func(notification) {
	        if (notification.NotificationType == "OmniNotification") {
	        	#printf("RWR recv: %s", notification.NotificationType);
	            if (me.radar.enabled == 1) {
	    		    me.radar.vector_aicontacts = notification.vector;
	    		    me.radar.scan();
	    	    }
	            return emesary.Transmitter.ReceiptStatus_OK;
	        }
	        return emesary.Transmitter.ReceiptStatus_NotProcessed;
	    };
		emesary.GlobalTransmitter.Register(rr.RWRRecipient);
		rr.RWRNotification = VectorNotification.new("RWRNotification");
		rr.RWRNotification.updateV(rr.vector_aicontacts_threats);
		#rr.timer.start();
		return rr;
	},
	heatDefense: 0,
	scan: func {
		# sort in threat?
		# run by notification
		# mock up code, ultra simple threat index, is just here cause rwr have special needs:
		# 1) It has almost no range restriction
		# 2) Its omnidirectional
		# 3) It might have to update fast (like 0.25 secs)
		# 4) To build a proper threat index it needs at least these properties read:
		#       model type
		#       class (AIR/SURFACE/MARINE)
		#       lock on myself
		#       missile launch
		#       transponder on/off
		#       bearing and heading
		#       IFF info
		#       ECM
		#       radar on/off
		#if (!getprop("instrumentation/rwr/serviceable") or getprop("f16/avionics/power-ufc-warm") != 1 or getprop("f16/ews/ew-rwr-switch") != 1) {
        #    setprop("sound/rwr-lck", 0);
        #    setprop("ai/submodels/submodel[0]/flare-auto-release-cmd", 0);
        #    return;
        #}
        me.vector_aicontacts_threats = [];
		me.fct = 10*2.0;
        me.myCallsign = self.getCallsign();
        me.myCallsign = size(me.myCallsign) < 8 ? me.myCallsign : left(me.myCallsign,7);
        me.act_lck = 0;
        me.autoFlare = 0;
        me.closestThreat = 0;
        me.elapsed = elapsedProp.getValue();
        foreach(me.u ; me.vector_aicontacts) {
        	# [me.ber,me.head,contact.getCoord(),me.tp,me.radar,contact.getDeviationHeading(),contact.getRangeDirect()*M2NM, contact.getCallsign()]
        	me.threatDB = me.u.getThreatStored();
            me.cs = me.threatDB[7];
            me.rn = me.threatDB[6];
            if ((me.u["blue"] != nil and me.u.blue == 1 and !me.threatDB[10]) or me.rn > 175) {
                continue;
            }
            me.bearing = me.threatDB[0];
            me.trAct = me.threatDB[3];
            me.show = 1;
            me.heading = me.threatDB[1];
            me.inv_bearing =  me.bearing+180;#bearing from target to me
            me.deviation = me.inv_bearing - me.heading;# bearing deviation from target to me
            me.dev = math.abs(geo.normdeg180(me.deviation));# my degrees from opponents nose

            if (me.show == 1) {
                if (me.dev < 30 and me.rn < 7 and me.threatDB[8] > 60) {
                    # he is in position to fire heatseeker at me
                    me.heatDefenseNow = me.elapsed + me.rn*1.5;
                    if (me.heatDefenseNow > me.heatDefense) {
                        me.heatDefense = me.heatDefenseNow;
                    }
                }
                me.threat = 0;
                if (me.u.getModel() != "missile_frigate" and me.u.getModel() != "S-75" and me.u.getModel() != "SA-6" and me.u.getModel() != "buk-m2" and me.u.getModel() != "MIM104D" and me.u.getModel() != "s-200" and me.u.getModel() != "s-300" and me.u.getModel() != "fleet" and me.u.getModel() != "ZSU-23-4M") {
                    me.threat += ((180-me.dev)/180)*0.30;# most threat if I am in front of his nose
                    me.spd = (60-me.threatDB[8])/60;
                    #me.threat -= me.spd>0?me.spd:0;# if his speed is lower than 60kt then give him minus threat else positive
                } elsif (me.u.getModel() == "missile_frigate" or me.u.getModel() == "fleet") {
                    me.threat += 0.30;
                } else {
                    me.threat += 0.30;
                }
                me.danger = 50;# within this range he is most dangerous
                if (me.u.getModel() == "missile_frigate" or me.u.getModel() == "fleet" or me.u.getModel() == "s-300") {
                    me.danger = 80;
                } elsif (me.u.getModel() == "buk-m2" or me.u.getModel() == "S-75") {
                    me.danger = 35;
                } elsif (me.u.getModel() == "SA-6") {
                    me.danger = 15;
                } elsif (me.u.getModel() == "s-200") {
                    me.danger = 150;
                } elsif (me.u.getModel() == "MIM104D") {
                    me.danger = 45;
                } elsif (me.u.getModel() == "ZSU-23-4M") {
                    me.danger = 7.5;
                }
                if (me.threatDB[10]) me.threat += 0.30;# has me locked
                me.threat += ((me.danger-me.rn)/me.danger)>0?((me.danger-me.rn)/me.danger)*0.60:0;# if inside danger zone then add threat, the closer the more.
                me.threat += me.threatDB[9]>0?(me.threatDB[9]/500)*0.10:0;# more closing speed means more threat.
                if (me.u.getModel() == "AI") me.threat = 0.01;
                if (contains(noRadarList, me.u.getModel())) me.threat = - 1;
                if (me.threat > me.closestThreat) me.closestThreat = me.threat;
                #printf("A %s threat:%.2f range:%d dev:%d", me.u.get_Callsign(),me.threat,me.u.get_range(),me.deviation);
                if (me.threat > 1) me.threat = 1;
                if (me.threat <= 0) continue;
                #printf("B %s threat:%.2f range:%d dev:%d", me.u.get_Callsign(),me.threat,me.u.get_range(),me.deviation);
                append(me.vector_aicontacts_threats,[me.u,me.threat, me.threatDB[5]]);
            } else {
#                printf("%s ----", me.u.get_Callsign());
            }
        }

        me.launchClose = getprop("payload/armament/MLW-launcher") != "";
        me.incoming = getprop("payload/armament/MAW-active") or getprop("payload/armament/MAW-semiactive") or me.heatDefense > me.elapsed;
        me.spike = 0;#getprop("payload/armament/spike")*(getprop("ai/submodels/submodel[0]/count")>15);
        me.autoFlare = me.spike?math.max(me.closestThreat*0.25,0.05):0;

        if (0 and getprop("f16/ews/ew-mode-knob") == 2)
        	print("wow: ", getprop("/fdm/jsbsim/gear/unit[0]/WOW"),"  spiked: ",me.spike,"  incoming: ",me.incoming, "  launch: ",me.launchClose,"  spikeResult:", me.autoFlare,"  aggresive:",me.launchClose * 0.85 + me.incoming * 0.85,"  total:",me.launchClose * 0.85 + me.incoming * 0.85+me.autoFlare);

        me.autoFlare += me.launchClose * 0.85 + me.incoming * 0.85;

        me.autoFlare *= 0.1 * 2.5 * !getprop("/fdm/jsbsim/gear/unit[0]/WOW");#0.1 being the update rate for flare dropping code.

        setprop("ai/submodels/submodel[0]/flare-auto-release-cmd", me.autoFlare * (getprop("ai/submodels/submodel[0]/count")>0));
        if (me.autoFlare > 0.80 and rand()>0.99 and getprop("ai/submodels/submodel[0]/count") < 1) {
            setprop("ai/submodels/submodel[0]/flare-release-out-snd", 1);
        }
        emesary.GlobalTransmitter.NotifyAll(me.RWRNotification.updateV(me.vector_aicontacts_threats));
	},
	del: func {
        emesary.GlobalTransmitter.DeRegister(me.RWRRecipient);
    },
};



















var scanInterval = 0.05;# 20hz for main radar


laserOn = props.globals.getNode("payload/armament/laser-arm-switch",1);#don't put 'var' keyword in front of this.
var datalink_power = props.globals.getNode("instrumentation/datalink/power",0);
enable_tacobject = 0;
var antennae_knob_prop = props.globals.getNode("instrumentation/radar/antennae-knob",0);
var wndprop = props.globals.getNode("environment/wind-speed-kt",0);


# start generic radar system
var baser = AIToNasal.new();
var partitioner = NoseRadar.new();
var omni = OmniRadar.new(1.0, 150, -1);
var terrain = TerrainChecker.new(0.05, 1, 30);# 0.05 or 0.10 is fine here
var callsignToContact = CallsignToContact.new();
var dlnkRadar = DatalinkRadar.new(0.03, 110, 225);# 3 seconds because cannot be too slow for DLINK targets
var ecm = ECMChecker.new(0.05, 6);

# start specific radar system
var rwsMode = SearchMode.new();
var apy1Radar = AirborneRadar.newAirborne([[rwsMode]], APY1);
var f16_rwr = RWR.new();




var getCompleteList = func {
	return baser.vector_aicontacts_last;
}


var armament = {
	contact: nil,
	POINT: 4,
};
var steerpoints = {
	sending: nil,
};
setprop("instrumentation/mptcas/display-factor-awacs",0.5);

# BUGS:
#   HSD radar arc CW vs. CCW
#
# TODO:
#   VS switch speed at each bar instead of each frame
#
