/// Flutter support for trusted, read-only mobile workspace grants.
library workspace_flutter;

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:workspace/workspace.dart';

part 'src/grant_manager.dart';
part 'src/method_channel_workspace_bridge.dart';
