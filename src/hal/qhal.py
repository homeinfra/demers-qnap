#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# This script is used to handle the SuperIO chip I/O operations

import ast
from collections import namedtuple
from datetime import datetime
import os
from pathlib import Path
from subprocess import Popen, PIPE, run
import argparse
import socket
import daemon
import signal
import logging
from portio import ioperm, inb, outb

# Define some values for the supported HAL features
IO = namedtuple('IO', ['name', 'port', 'bit'])
SOUND = namedtuple('SOUND', ['name', 'id'])
SENSOR = namedtuple('SENSOR', ['name'])

# Define the list of LEDs
# Apparently the first two disks have access to a blinking LED, via I2C.
leds = [
  IO(name='Status_Green', port=0x91, bit=2),
  IO(name='Status_Red', port=0x91, bit=3),
  IO(name='Front_USB', port=0xE1, bit=7),
  IO(name='Disk1_Present', port=0xB1, bit=2),
  IO(name='Disk2_Present', port=0xB1, bit=3),
  IO(name='Disk1_Error', port=0x81, bit=0),
  IO(name='Disk2_Error', port=0x81, bit=1),
  IO(name='Disk3_Error', port=0x81, bit=2),
  IO(name='Disk4_Error', port=0x81, bit=3),
  IO(name='Disk5_Error', port=0x81, bit=4),
  IO(name='Disk6_Error', port=0x81, bit=5),
]

# Define the list of buttons
buttons = [
  IO(name='Reset', port=0x92, bit=1),
  IO(name='USB_Copy', port=0xE2, bit=2),
]

# Define the list of sounds the buzzer can generate
#
# List of supported sounds comes from:
# https://sandrotosi.blogspot.com/2021/05/qnap-control-lcd-panel-and-speaker.html
sounds = [
  SOUND(name='Beep', id=0),
  SOUND(name='Online', id=1),
  SOUND(name='Ready', id=2),
  SOUND(name='Alert', id=3),
  SOUND(name='Outage', id=8),
  SOUND(name='Completed', id=12),
  SOUND(name='Error', id=14),
]

temps = [
  SENSOR(name='CPU'),
  SENSOR(name='Eth2'),
  SENSOR(name='Temp1'),
  SENSOR(name='Temp2'),
  SENSOR(name='Temp3'),
]

fans = [
  SENSOR(name='Fan1'),
  SENSOR(name='Fan2'),
]

SOCKET_PATH = '/tmp/qhal_daemon.sock'
PID_FILE = '/tmp/qhal_daemon.pid'
SOCKET_TIMEOUT = 0.1

IO_REG_PORT = 0xa05
IO_REG_DATA = IO_REG_PORT + 1
IO_REG_COUNT = 2

class QhalDaemon:
  def __init__(self):
    self.__log_config = LoggerConfig(name=f"{Path(__file__).stem}_daemon")
    self.__log = self.__log_config.get_logger()
    self.__btnHandler = ButtonHandler(self.__log)
    self.__ledHandler = LedHandler(self.__log)
    
    # Set up signal handlers
    signal.signal(signal.SIGTERM, self.__handle_signal)
    signal.signal(signal.SIGINT, self.__handle_signal)

  def __handle_signal(self, signum, frame):
    self.__log.info(f"Received signal {signum}, stopping daemon...")
    self.__running = False

  def handle_command(self, command):
    parts = command.split()
    cmd = parts[0]
    args = parts[1:]

    if cmd == 'led':
      return self.__ledHandler.command(args)
    elif cmd == 'button':
      return self.__btnHandler.command(args)
    else:
      return f'Unknown command: {cmd}'

  def run(self):
    self.__log.info('== Daemon Started ==')
    try:
      if os.path.exists(SOCKET_PATH):
        os.remove(SOCKET_PATH)
        
      status = ioperm(IO_REG_PORT, IO_REG_COUNT, 1)
      if status:
        raise Exception('Failed to get I/O permissions')
      
      with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server_socket:
        server_socket.bind(SOCKET_PATH)
        server_socket.listen()
        server_socket.settimeout(SOCKET_TIMEOUT)

        self.__running = True
        while self.__running:
          try:
            conn, _ = server_socket.accept()
            with conn:
              data = conn.recv(1024)
              if data:
                try:
                  response = self.handle_command(data.decode())
                  conn.sendall(response.encode())
                except NotImplementedError as e:
                  conn.sendall(f'Command not yet implemented'.encode())
                except Exception as e:
                  self.__log.critical('Failed to handle command', exc_info=e)
                  conn.sendall(f'Could not process command: {data.decode()}'.encode())
          except socket.timeout:
            # Run background tasks periodically
            self.__btnHandler.run()
            
      # Clean-up logic here
      self.__log.info('== Daemon Exited gracefully ==')
      os._exit(0)
    except Exception as e:
      self.__log.critical('Daemon failed', exc_info=e)
    finally:
      status = ioperm(IO_REG_PORT, IO_REG_COUNT, 0)
      if status:
        self.__log.error('Failed to release I/O permissions')

class IOHandler:
  def __init__(self, logger):
    self._log = logger
    
  def read_io(self, io, with_logs=True):
    outb(io.port, IO_REG_PORT)
    val = inb(IO_REG_DATA)
    if with_logs:
      self._log.info(f'Raw value read for {io.name} value: {hex(val)}')
    val = 1 if val & (1 << io.bit) else 0
    if with_logs:
      self._log.info(f'Bit for {io.name}: {val}. Returning the opposite')
    return 0 if val else 1

  def write_io(self, io, value, with_logs=True):
    outb(io.port, IO_REG_PORT)
    pre_val = inb(IO_REG_DATA)
    if with_logs:
      self._log.info(f'Raw value read for {io.name} value: {hex(pre_val)}')
    val = 0 if value else 1
    mask = 1 << io.bit
    post_val = pre_val & ~mask | val << io.bit
    if with_logs:
      self._log.info(f'Writing {hex(post_val)} ({val}) to {io.name} for bit {io.bit}')
    outb(post_val, IO_REG_DATA)

class ButtonHandler(IOHandler):
  def __init__(self, logger):
    super(ButtonHandler, self).__init__(logger)
    
    # Construct a dictionnary of buttons,
    # where the value is the command to execute
    self.__commands = {button: None for button in buttons}
    self.__prev_state = {button: None for button in buttons}
    
  def get_button(self, button):
    # Implement the button command logic here
    return self.read_io(button, with_logs=False)
    
  def command(self, args):
    if len(args) < 1:
      self._log.error(f'Invalid number of arguments: {args}')
      return 'Usage: button <name> -- <to_execute>'
    if args[0] not in [btn.name for btn in buttons]:
      self._log.error(f'Unknown button: {args[0]}')
      return f'Unknown button: {args[0]}'
    
    button = next((b for b in buttons if b.name == args[0]), None)
    
    if len(args) < 2:
      self._log.error(f'Expected at least an empty list of arguments for the command')
      return f'Unexpected error while configuring button {button.name}'
    
    # Parse the remaining arguments from an array with square brackets
    to_execute = ast.literal_eval(' '.join(args[1:]))
    if len(to_execute) == 0:
      # We are disabling the previous command, if any
      self.__commands[button] = None
      self._log.info(f'Button {button.name} command disabled')
      return f'Button {button.name} command disabled'
    else:
      before = self.__commands[button]
      self.__commands[button] = to_execute
      self._log.info(f'Button {button.name} set to execute: {self.__commands[button]}. Before: {before}')
      return f'Button {button.name} command set to: {self.__commands[button]}'
    
  def run(self):    
    for button in buttons:
      try:
        state = self.get_button(button)
        if self.__prev_state[button] is None:
          self._log.info(f'Button {button.name} was initialized to: {state}')
          self.__prev_state[button] = state
        elif state != self.__prev_state[button]:
          self._log.info(f'Button {button.name} changed state from {self.__prev_state[button]} to {state}')
          self.__prev_state[button] = state
          if state == 0:
            self._log.info(f'Button {button.name} was released. Executing command: {self.__commands[button]}')
            try:
              if self.__commands[button] is not None:
                res = Popen(self.__commands[button], stdout=PIPE, stderr=PIPE)
                res.communicate()
                self._log.info(f'Command [{self.__commands[button]}] executed with result: {res.returncode}')
                if res.returncode:
                  self._log.error(f'Command failed with return code: {res.returncode}. Stderr: {res.stderr}. Stdout: {res.stdout}. Stdout: {res.stdout}')
              else:
                self._log.info(f'No command configured for button {button.name}')
            except Exception as e:
              self._log.error(f'Failed to execute command', exc_info=e)
          else:
            self._log.info(f'Button {button.name} was pressed')
      except Exception as e:
        self._log.error(f'Failed to get button state', exc_info=e)

class LedHandler(IOHandler):
  def __init__(self, logger):
    super(LedHandler, self).__init__(logger)
    
  def set_led(self, led, state):
    # Implement the led command logic here
    self._log.info(f'Setting LED {led.name} to {state}')
    if state == 'on':
      self.write_io(led, 1)
    elif state == 'off':
      self.write_io(led, 0)
    else:
      raise ValueError(f'Invalid state: {state}')
    
  def get_led(self, led):
    # Implement the led command logic here
    self._log.info(f'Getting LED {led.name} state')
    return "on" if self.read_io(led) else "off"
    
  def command(self, args):
    if len(args) > 2 or len(args) < 1:
      self._log.error(f'Invalid number of arguments: {args}')
      return 'Usage: led <enum> <on|off>'
    
    if args[0] not in [led.name for led in leds]:
      self._log.error(f'Unknown LED: {args[0]}')
      return f'Unknown LED: {args[0]}'
    
    led = next((l for l in leds if l.name == args[0]), None)
    if len(args) == 1:
      try:
        state = self.get_led(led)
        return f'LED {led.name} is {state}'
      except Exception as e:
        self._log.error(f'Failed to get LED state', exc_info=e)
        return f'Failure to get LED state: {e.message}'
    else:
      state = args[1]
      if state not in ['on', 'off']:
        return f'Unknown state: {state}'
      try:
        self.set_led(led, state)
        return f'Ok. LED {led.name} is now {state}'
      except Exception as e:
        self._log.error(f'Failed to set LED state', exc_info=e)
        return f'Failure to set LED state: {e.message}'
    

  def run(self):
    # Implement the led command logic here
    self._log.info('Led handler ran')

class QhalClient:
  def __init__(self, logger):
    self.__log = logger

  def handle_temp_command(self, arg):
    if len(arg) <= 1:
      self.__log.error('Not enough arguments provided for temp command')
      print('Usage: temp <sensor>')
      return
    
    # Arguments
    sensor = next((s for s in temps if s.name == arg), None)
    self.__log.info(f"Reading temperature for sensor: {sensor.name}")
    
  def handle_fan_command(self, arg):
    if len(arg) <= 1:
      self.__log.error('Not enough arguments provided for fan command')
      print('Usage: fan <fan>')
      return
    
    # Arguments
    fan = next((s for s in fans if s.name == arg), None)
    self.__log.info(f"Reading fan speed for fan: {fan.name}")

  def handle_beep_command(self, arg):
    if len(arg) <= 1:
      self.__log.error('Not enough arguments provided for beep command')
      print('Usage: beep <sound>')
      return
    
    # Arguments
    sound = next((s for s in sounds if s.name == arg), None)
    
    res = Popen(['qnap_hal', 'hal_app', '--se_buzzer', f"enc_id=0,mode={sound.id}"], stdout=PIPE, stderr=PIPE)
    res.communicate()
    if res.returncode:
      self.__log.error(f"Failed to play sound: {sound.name}. Return Code: {res.returncode}. Stderr: {res.stderr}. Stdout: {res.stdout}")
      print(f"Failed to play sound: {sound.name}")

def start_daemon(logger):
  if os.path.exists(PID_FILE):
    with open(PID_FILE, 'r') as f:
      try:
        pid = int(f.read().strip())
        os.kill(pid, 0)
        logger.info("Daemon is already running")
        print("Daemon is already running")
        return
      except ProcessLookupError:
        logger.warning("Stale PID file found. Removing it.")
        print("Stale PID file found. Removing it.")
        os.remove(PID_FILE)
  
  logger.info('Starting daemon...')
  # Fork the process
  pid = os.fork()
  if pid > 0:
      # Parent process
      logger.info(f"Forked PID {pid}")
  else:
      # Child process
      with daemon.DaemonContext():
        with open(PID_FILE, 'w') as f:
          f.write(str(os.getpid()))
        QhalDaemon().run()

def stop_daemon(logger):
  if os.path.exists(PID_FILE):
    with open(PID_FILE, 'r') as f:
      try:
        pid = int(f.read().strip())
        os.kill(pid, signal.SIGTERM)
        os.remove(PID_FILE)
        logger.info("Daemon stopped")
        print("Daemon stopped")
      except ProcessLookupError:
        logger.warning("Stale PID file found. Daemon is not running")
        os.remove(PID_FILE)
        print("Daemon is not running")
  else:
    logger.info("Daemon was not running")
    print("Daemon is not running")

def status_daemon(logger):
  if os.path.exists(PID_FILE):
    with open(PID_FILE, 'r') as f:
      try:
        pid = int(f.read().strip())
        os.kill(pid, 0)
        logger.info("Daemon is running")
        print("Daemon is running")
      except ProcessLookupError:
        logger.warning("Stale PID file found. Daemon is not running")
        os.remove(PID_FILE)
        print("Daemon is not running")
  else:
    logger.info("Daemon is not running")
    print("Daemon is not running")

def main():
  logger = LoggerConfig().get_logger()
  try:
    logger.info('== %s Started ==', Path(__file__).name)
    
    client = QhalClient(logger)
    
    args = parse()
    if args is not None:    
      if args.command == 'start':
        start_daemon(logger)
      elif args.command == 'stop':
        stop_daemon(logger)
      elif args.command == 'status':
        status_daemon(logger)
      elif args.command == 'beep':
        client.handle_beep_command(args.sound)
      elif args.command == 'temp':
        client.handle_temp_command(args.sensor)
      elif args.command == 'fan':
        client.handle_fan_command(args.fan)
      else:
        command = f"{' '.join(str(v) for v in vars(args).values() if v is not None)}"
        logger.info(f"Sending command to daemon: {command}")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client_socket:
          try:
            client_socket.connect(SOCKET_PATH)
            client_socket.sendall(command.encode())
            response = client_socket.recv(1024).decode()
            logger.info(f"Response: {response}")
            print(response)
          except ConnectionRefusedError as e:
            logger.error("Could not connect to daemon. Is it running?", exc_info=e)
            print("No response from daemon. Is it running?")
    else:
      logger.error('No arguments provided')
    
    logger.info('== %s Exited gracefully ==', Path(__file__).name)
  except Exception as e:
    logger.critical('== %s Failed ==', Path(__file__).name, exc_info=e)

def parse():
  parser = argparse.ArgumentParser(description='''
      QNAP HAL API. Includes a daemon that monitors the hardware for button press events,
      can control LEDs, the LCD pannel and read sensors.
      ''')
  subparsers = parser.add_subparsers(dest='command', help='Command to control the daemon')

  subparsers.add_parser('start', help='Start the daemon')
  subparsers.add_parser('stop', help='Stop the daemon')
  subparsers.add_parser('status', help='Check the status of the daemon')

  beep_parser = subparsers.add_parser('beep', help='Execute beep command')
  beep_parser.add_argument('sound', choices=[s.name for s in sounds], help='Sound to play')

  led_parser = subparsers.add_parser('led', help='Set LED state')
  led_parser.add_argument('name', choices=[led.name for led in leds], help='LED name')
  led_parser.add_argument('state', choices=['on', 'off'], nargs='?', help='LED state')

  button_parser = subparsers.add_parser('button', help='Set button command')
  button_parser.add_argument('name', choices=[button.name for button in buttons], help='Button name')
  button_parser.add_argument('to_execute', nargs=argparse.REMAINDER, help='Command to execute when the button is pressed')

  temp_parser = subparsers.add_parser('temp', help='Read temperature')
  temp_parser.add_argument('sensor', choices=[temp.name for temp in temps], help='Sensor to read')
  
  fan_parser = subparsers.add_parser('fan', help='Read fan speed')
  fan_parser.add_argument('fan', choices=[fan.name for fan in fans], help='Fan to read')

  args = parser.parse_args()
  if args.command is None:
    parser.print_help()
    return None

  return args

class LoggerConfig:
  """Logger configuration"""
    
  def __init__(self, name=Path(__file__).stem):
    """Configure the root logger"""
    self.__filename = f'{ROOT}/.log/{name}_' \
                      f'{datetime.now().strftime("%F_%H%M%S")}.log'
    Path(self.__filename).parent.mkdir(parents=True, exist_ok=True)
    
    level = logging.DEBUG # Default value
    format = '%(asctime)s [%(levelname)-7s] %(message)s'
    datefmt = '%F %H:%M:%S'
    
    self.__logger = logging.getLogger(name)
    self.__logger.setLevel(level)
    
    self.__console = logging.StreamHandler()
    self.__console.setLevel(level)
    self.__console.setFormatter(logging.Formatter(format, datefmt))
    
    self.__file = logging.FileHandler(filename=self.__filename, encoding='utf-8', mode='a+')
    self.__file.setLevel(level)
    self.__file.setFormatter(logging.Formatter(format, datefmt))
    
    self.__logger.addHandler(self.__console)
    self.__logger.addHandler(self.__file)
    
    self.reconfigure()
        
        # Levels as defined by logger-shell
  def _set_level(self, level):
    level = logging.NOTSET
    
    if level == 3:
      level = logging.DEBUG
    elif level == 4:
      level = logging.INFO
    elif level == 5:
      level = logging.WARNING
    elif level == 6:
      level = logging.ERROR
    elif level == 7:
      level = logging.CRITICAL
      
    self.__logger.setLevel(level)
    self.__console.setLevel(level)
    self.__file.setLevel(level)

  def get_logger(self):
    return self.__logger

  def reconfigure(self):
    """Force a reconfiguration of the logger."""
    if 'LOG_LEVEL' in os.environ:
      level = int(os.environ['LOG_LEVEL'])
      self._set_level(level)

      if 'LOG_CONSOLE' in os.environ:
        if int(os.environ['LOG_CONSOLE']) == 0:
          self.__logger.removeHandler(self.__console)
        else:
          self.__logger.addHandler(self.__console)

# Get ROOT
ROOT = os.path.realpath(os.path.dirname(os.path.abspath(__file__)) + "/..")

if __name__ == "__main__":
  main()
else:
  raise Exception(f"{__file__} is not a library")